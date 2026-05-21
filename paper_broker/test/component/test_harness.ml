(** In-process test harness for the paper_broker BC.

    Drives the application-layer workflows directly (no Bus), so the
    component boundary covered by these scenarios includes the
    Order_store and Order_command_log adapters and the outbound
    integration-event projection. The Hexagonal outbound ports
    [publish_*] are substituted with in-memory recorders. *)

module Submit_wf = Paper_broker_commands.Submit_order_command_workflow
module Apply_bar_wf = Paper_broker_commands.Apply_bar_command_workflow
module Cancel_wf = Paper_broker_commands.Cancel_pending_order_command_workflow
module Order_accepted_ie =
  Paper_broker_integration_events.Order_accepted_integration_event
module Order_filled_ie =
  Paper_broker_integration_events.Order_leg_filled_integration_event
module Order_rejected_ie =
  Paper_broker_integration_events.Order_rejected_integration_event
module Order_cancelled_ie =
  Paper_broker_integration_events.Order_cancelled_integration_event
module Slippage_bps = Paper_broker.Slippage.Values.Slippage_bps
module Fee_rate = Paper_broker.Fee.Values.Fee_rate

(** Single-threaded in-memory adapter for the
    {!Paper_broker_store.Order_store.S} port. Mirrors
    {!Paper_broker_persistence.In_memory_order_store} without the
    Mutex (Alcotest scenarios are sequential). Kept in-test so the
    component layer doesn't pull the infrastructure library. *)
module Test_store = struct
  module Order = Paper_broker.Order

  type t = (string, Order.t) Hashtbl.t

  let create () : t = Hashtbl.create 8

  let save (t : t) (order : Order.t) =
    if Hashtbl.mem t order.id then `Already_exists
    else begin
      Hashtbl.replace t order.id order;
      `Ok
    end

  let find (t : t) ~id : Order.t option = Hashtbl.find_opt t id

  let find_active (t : t) : Order.t list =
    Hashtbl.fold
      (fun _ order acc -> if Order.is_terminal order then acc else order :: acc)
      t []

  let update (t : t) ~id ~f =
    match Hashtbl.find_opt t id with
    | None -> `Not_found
    | Some current ->
        (match f current with
        | `Replace order -> Hashtbl.replace t id order
        | `Delete -> Hashtbl.remove t id);
        `Updated

  let update_by_placement_id (t : t) ~placement_id ~f =
    let found =
      Hashtbl.fold
        (fun _ order acc ->
          match acc with
          | Some _ -> acc
          | None ->
              if Order.Values.Placement_id.to_int order.Order.placement_id = placement_id
              then Some order
              else None)
        t None
    in
    match found with
    | None -> `Not_found
    | Some current ->
        (match f current with
        | `Replace order -> Hashtbl.replace t current.id order
        | `Delete -> Hashtbl.remove t current.id);
        `Updated

  let length (t : t) : int = Hashtbl.length t
end

(** Single-threaded in-memory adapter for the
    {!Paper_broker_store.Order_command_log.S} port. *)
module Test_command_log = struct
  type entry = { submit : string option; cancel : string option }
  type t = (string, entry) Hashtbl.t

  let create () : t = Hashtbl.create 8

  let get_entry t aggregate_id =
    match Hashtbl.find_opt t aggregate_id with
    | Some e -> e
    | None -> { submit = None; cancel = None }

  let record_submit t ~aggregate_id ~correlation_id =
    let cur = get_entry t aggregate_id in
    Hashtbl.replace t aggregate_id { cur with submit = Some correlation_id }

  let record_cancel t ~aggregate_id ~correlation_id =
    let cur = get_entry t aggregate_id in
    Hashtbl.replace t aggregate_id { cur with cancel = Some correlation_id }

  let origin_correlation_id t ~aggregate_id =
    match Hashtbl.find_opt t aggregate_id with
    | Some e -> e.submit
    | None -> None

  let cancel_correlation_id t ~aggregate_id =
    match Hashtbl.find_opt t aggregate_id with
    | Some e -> e.cancel
    | None -> None
end

let store_module =
  (module Test_store : Paper_broker_store.Order_store.S with type t = Test_store.t)

let log_module =
  (module Test_command_log : Paper_broker_store.Order_command_log.S
    with type t = Test_command_log.t)

type ctx = {
  store : Test_store.t;
  command_log : Test_command_log.t;
  next_order_id : unit -> string;
  next_exec_id : unit -> string;
  slippage_bps : Slippage_bps.t;
  fee_rate : Fee_rate.t;
  participation_rate : Paper_broker.Matching.Values.Participation_rate.t option;
  now_ts_ref : int64 ref;
  last_seen_bar_ts : (Core.Instrument.t, int64) Hashtbl.t;
  order_accepted_pub : Order_accepted_ie.t list ref;
  order_filled_pub : Order_filled_ie.t list ref;
  order_rejected_pub : Order_rejected_ie.t list ref;
  order_cancelled_pub : Order_cancelled_ie.t list ref;
}

let make_id_seq prefix =
  let r = ref 0 in
  fun () ->
    incr r;
    Printf.sprintf "%s-%d" prefix !r

let fresh_ctx () =
  {
    store = Test_store.create ();
    command_log = Test_command_log.create ();
    next_order_id = make_id_seq "po";
    next_exec_id = make_id_seq "ex";
    slippage_bps = Slippage_bps.zero;
    fee_rate = Fee_rate.zero;
    participation_rate = None;
    now_ts_ref = ref 1_700_000_000L;
    last_seen_bar_ts = Hashtbl.create 8;
    order_accepted_pub = ref [];
    order_filled_pub = ref [];
    order_rejected_pub = ref [];
    order_cancelled_pub = ref [];
  }

let with_slippage_bps ctx ~bps =
  { ctx with slippage_bps = Slippage_bps.of_decimal (Decimal.of_string bps) }

let with_fee_rate ctx ~rate =
  { ctx with fee_rate = Fee_rate.of_decimal (Decimal.of_string rate) }

let with_participation_rate ctx ~rate =
  {
    ctx with
    participation_rate =
      Some
        (Paper_broker.Matching.Values.Participation_rate.of_decimal
           (Decimal.of_string rate));
  }

let placed_after_ts_for ctx instrument =
  match Hashtbl.find_opt ctx.last_seen_bar_ts instrument with
  | Some ts -> ts
  | None -> 0L

let submit_market_buy
    ?(correlation_id = "saga-1")
    ?(placement_id = 1)
    ?(symbol = "SBER@MISX")
    ?(quantity = "10")
    ()
    ctx =
  let cmd : Paper_broker_commands.Submit_order_command.t =
    {
      correlation_id;
      placement_id;
      symbol;
      side = "BUY";
      quantity;
      kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
      tif = "GTC";
    }
  in
  let publish_accepted e = ctx.order_accepted_pub := e :: !(ctx.order_accepted_pub) in
  let publish_rejected e = ctx.order_rejected_pub := e :: !(ctx.order_rejected_pub) in
  let _ =
    Submit_wf.execute ~store:store_module ~store_handle:ctx.store ~command_log:log_module
      ~command_log_handle:ctx.command_log ~next_order_id:ctx.next_order_id
      ~now_ts:(fun () -> !(ctx.now_ts_ref))
      ~placed_after_ts:(placed_after_ts_for ctx) ~publish_order_accepted:publish_accepted
      ~publish_order_rejected:publish_rejected cmd
  in
  ctx

let submit_market_sell
    ?(correlation_id = "saga-1")
    ?(placement_id = 1)
    ?(symbol = "SBER@MISX")
    ?(quantity = "10")
    ()
    ctx =
  let cmd : Paper_broker_commands.Submit_order_command.t =
    {
      correlation_id;
      placement_id;
      symbol;
      side = "SELL";
      quantity;
      kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
      tif = "GTC";
    }
  in
  let publish_accepted e = ctx.order_accepted_pub := e :: !(ctx.order_accepted_pub) in
  let publish_rejected e = ctx.order_rejected_pub := e :: !(ctx.order_rejected_pub) in
  let _ =
    Submit_wf.execute ~store:store_module ~store_handle:ctx.store ~command_log:log_module
      ~command_log_handle:ctx.command_log ~next_order_id:ctx.next_order_id
      ~now_ts:(fun () -> !(ctx.now_ts_ref))
      ~placed_after_ts:(placed_after_ts_for ctx) ~publish_order_accepted:publish_accepted
      ~publish_order_rejected:publish_rejected cmd
  in
  ctx

let submit_limit_buy
    ?(correlation_id = "saga-1")
    ?(placement_id = 1)
    ?(symbol = "SBER@MISX")
    ?(quantity = "10")
    ~limit
    ()
    ctx =
  let cmd : Paper_broker_commands.Submit_order_command.t =
    {
      correlation_id;
      placement_id;
      symbol;
      side = "BUY";
      quantity;
      kind =
        { type_ = "LIMIT"; price = Some limit; stop_price = None; limit_price = None };
      tif = "GTC";
    }
  in
  let publish_accepted e = ctx.order_accepted_pub := e :: !(ctx.order_accepted_pub) in
  let publish_rejected e = ctx.order_rejected_pub := e :: !(ctx.order_rejected_pub) in
  let _ =
    Submit_wf.execute ~store:store_module ~store_handle:ctx.store ~command_log:log_module
      ~command_log_handle:ctx.command_log ~next_order_id:ctx.next_order_id
      ~now_ts:(fun () -> !(ctx.now_ts_ref))
      ~placed_after_ts:(placed_after_ts_for ctx) ~publish_order_accepted:publish_accepted
      ~publish_order_rejected:publish_rejected cmd
  in
  ctx

let bar_arrives
    ?(symbol = "SBER@MISX")
    ?(ts = "2024-01-01T10:00:00Z")
    ?(open_ = "100")
    ?(high = "105")
    ?(low = "95")
    ?(close = "102")
    ?(volume = "1000")
    ()
    ctx =
  let cmd : Paper_broker_commands.Apply_bar_command.t =
    {
      instrument = symbol;
      timeframe = "1m";
      candle = { ts; open_; high; low; close; volume };
    }
  in
  let publish_filled e = ctx.order_filled_pub := e :: !(ctx.order_filled_pub) in
  let _ =
    Apply_bar_wf.execute ~store:store_module ~store_handle:ctx.store
      ~command_log:log_module ~command_log_handle:ctx.command_log
      ~slippage_bps:ctx.slippage_bps ~fee_rate:ctx.fee_rate
      ~participation_rate:ctx.participation_rate ~next_exec_id:ctx.next_exec_id
      ~publish_order_filled:publish_filled cmd
  in
  let bar_ts = Datetime.Iso8601.parse ts in
  if not (Int64.equal bar_ts 0L) then begin
    let instrument = Core.Instrument.of_qualified symbol in
    Hashtbl.replace ctx.last_seen_bar_ts instrument bar_ts
  end;
  ctx

let cancel_order ?(correlation_id = "cancel-1") ~placement_id () ctx =
  let cmd : Paper_broker_commands.Cancel_pending_order_command.t =
    { correlation_id; placement_id }
  in
  let publish_cancelled e = ctx.order_cancelled_pub := e :: !(ctx.order_cancelled_pub) in
  let _ =
    Cancel_wf.execute ~store:store_module ~store_handle:ctx.store ~command_log:log_module
      ~command_log_handle:ctx.command_log
      ~now_ts:(fun () -> !(ctx.now_ts_ref))
      ~publish_order_cancelled:publish_cancelled cmd
  in
  ctx
