module Pair_mean_reversion = Portfolio_management.Pair_mean_reversion
module Pair_kalman_mean_reversion = Portfolio_management.Pair_kalman_mean_reversion
module Common = Portfolio_management.Common

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

type ok = {
  intents : Common.Construction_intent.t list;
  mark : Core.Instrument.t * Decimal.t;
}

let handle
    ~(pair_mr_states_for : Core.Instrument.t -> Pair_mean_reversion.state ref list)
    ~(pair_kalman_mr_states_for :
       Core.Instrument.t -> Pair_kalman_mean_reversion.state ref list)
    (cmd : Apply_bar_command.t) : (ok, handle_error) Rop.t =
  let parsed =
    let open Rop in
    let+ instrument = parse_instrument cmd.instrument
    and+ candle = parse_candle cmd.candle in
    (instrument, candle)
  in
  match parsed with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok (instrument, candle) ->
      let static_intents =
        List.fold_left
          (fun acc state_ref ->
            let state', intent_opt =
              Pair_mean_reversion.on_bar !state_ref ~instrument ~candle
            in
            state_ref := state';
            match intent_opt with
            | Some i -> i :: acc
            | None -> acc)
          []
          (pair_mr_states_for instrument)
      in
      let kalman_intents =
        List.fold_left
          (fun acc state_ref ->
            let state', intent_opt =
              Pair_kalman_mean_reversion.on_bar !state_ref ~instrument ~candle
            in
            state_ref := state';
            match intent_opt with
            | Some i -> i :: acc
            | None -> acc)
          []
          (pair_kalman_mr_states_for instrument)
      in
      Rop.succeed
        {
          intents = List.rev_append static_intents (List.rev kalman_intents);
          mark = (instrument, candle.close);
        }
