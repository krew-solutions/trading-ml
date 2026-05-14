module Order = Paper_broker.Order
module Matching = Paper_broker.Matching
module Slippage = Paper_broker.Slippage
module Fee = Paper_broker.Fee

type validation_error =
  | Invalid_instrument of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_ts of string
  | Invalid_candle of string

let validation_error_to_string = function
  | Invalid_instrument s -> Printf.sprintf "invalid instrument: %S" s
  | Invalid_decimal { field; value } ->
      Printf.sprintf "invalid decimal for %s: %S" field value
  | Invalid_ts s -> Printf.sprintf "invalid ts (ISO-8601 expected): %S" s
  | Invalid_candle s -> Printf.sprintf "invalid candle: %s" s

type handle_error = Validation of validation_error

type fill_outcome = { pending : Pending_order.t; event : Order.Events.Fill_observed.t }

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_instrument raw)

let parse_decimal ~field raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (Invalid_decimal { field; value = raw })

let parse_ts raw : (int64, validation_error) Rop.t =
  let parsed = Datetime.Iso8601.parse raw in
  if Int64.equal parsed 0L then Rop.fail (Invalid_ts raw) else Rop.succeed parsed

let parse_candle (candle : Apply_bar_command.candle_dto) :
    (Core.Candle.t, validation_error) Rop.t =
  let parsed_fields =
    let open Rop in
    let+ ts = parse_ts candle.ts
    and+ open_ = parse_decimal ~field:"open" candle.open_
    and+ high = parse_decimal ~field:"high" candle.high
    and+ low = parse_decimal ~field:"low" candle.low
    and+ close = parse_decimal ~field:"close" candle.close
    and+ volume = parse_decimal ~field:"volume" candle.volume in
    (ts, open_, high, low, close, volume)
  in
  match parsed_fields with
  | Error _ as e -> e
  | Ok (ts, open_, high, low, close, volume) -> (
      try Rop.succeed (Core.Candle.make ~ts ~open_ ~high ~low ~close ~volume)
      with Invalid_argument msg -> Rop.fail (Invalid_candle msg))

module type Store = Order_store.S

let try_fill_one
    (type store)
    ~(store : (module Store with type t = store))
    ~(store_handle : store)
    ~(slippage_bps : Slippage.Values.Slippage_bps.t)
    ~(fee_rate : Fee.Values.Fee_rate.t)
    ~(next_exec_id : unit -> string)
    ~(instrument : Core.Instrument.t)
    ~(candle : Core.Candle.t)
    (pending : Pending_order.t) : fill_outcome option =
  let module S = (val store : Store with type t = store) in
  let order = pending.order in
  if not (Core.Instrument.equal order.instrument instrument) then None
  else if Int64.compare candle.ts order.placed_after_ts <= 0 then None
  else
    match Matching.price_if_filled ~kind:order.kind ~side:order.side ~candle with
    | None -> None
    | Some canonical_price ->
        let fill_price = Slippage.apply ~bps:slippage_bps order.side canonical_price in
        let fill_quantity = Order.remaining order in
        let fee = Fee.compute ~rate:fee_rate ~quantity:fill_quantity ~price:fill_price in
        let exec_id = next_exec_id () in
        let outcome = ref None in
        let _ =
          S.update store_handle ~id:(Pending_order.id pending) ~f:(fun current ->
              match
                Order.apply_fill current.order ~exec_id ~fill_quantity ~fill_price ~fee
                  ~fill_ts:candle.ts
              with
              | Ok (order', event) ->
                  let pending' = Pending_order.with_order current order' in
                  outcome := Some { pending = pending'; event };
                  `Replace pending'
              | Error _ ->
                  (* Race: the order's status changed between [find_active]
                     and [update] (e.g. a concurrent cancel landed). Leave
                     the entry untouched and skip the fill. *)
                  `Replace current)
        in
        !outcome

let handle
    (type store)
    ~(store : (module Store with type t = store))
    ~(store_handle : store)
    ~(slippage_bps : Slippage.Values.Slippage_bps.t)
    ~(fee_rate : Fee.Values.Fee_rate.t)
    ~(next_exec_id : unit -> string)
    (cmd : Apply_bar_command.t) : (fill_outcome list, handle_error) Rop.t =
  let module S = (val store : Store with type t = store) in
  let parsed =
    let open Rop in
    let+ instrument = parse_instrument cmd.instrument
    and+ candle = parse_candle cmd.candle in
    (instrument, candle)
  in
  match parsed with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok (instrument, candle) ->
      let active = S.find_active store_handle in
      let fills =
        List.filter_map
          (try_fill_one ~store ~store_handle ~slippage_bps ~fee_rate ~next_exec_id
             ~instrument ~candle)
          active
      in
      Rop.succeed fills
