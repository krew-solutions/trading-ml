open Core

type t = {
  http_handler : Inbound_http.Route.handler;
  portfolio_snapshot : unit -> Account.Portfolio.t;
}

let build ~bus ~initial_cash ~market_price : t =
  let portfolio_ref = ref (Account.Portfolio.empty ~cash:initial_cash) in
  let next_reservation_id =
    let counter = ref 0 in
    fun () ->
      incr counter;
      !counter
  in
  (* TODO: replace with a per-instrument table or a live broker rate
     source. Account-internal stub today. *)
  let margin_policy : Account.Portfolio.Margin_policy.t =
   fun _instrument ->
    { margin_pct = Decimal.of_string "0.5"; haircut = Decimal.of_string "0.5" }
  in
  (* TODO: wire to a live mark stream. Domain falls back to position
     [avg_price] when [None] is returned, so buying-power computations
     remain grounded in entry cost until a real source is plugged in. *)
  let mark : Instrument.t -> Decimal.t option = fun _ -> None in
  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
  in
  let publish_amount_reserved =
    produce ~uri:"in-memory://account.amount-reserved"
      ~yojson_of:Account_integration_events.Amount_reserved_integration_event.yojson_of_t
  in
  let publish_reservation_released =
    produce ~uri:"in-memory://account.reservation-released"
      ~yojson_of:
        Account_integration_events.Reservation_released_integration_event.yojson_of_t
  in
  let publish_reservation_rejected =
    produce ~uri:"in-memory://account.reservation-rejected"
      ~yojson_of:
        Account_integration_events.Reservation_rejected_integration_event.yojson_of_t
  in
  let publish_reservation_filled =
    produce ~uri:"in-memory://account.reservation-filled"
      ~yojson_of:
        Account_integration_events.Reservation_filled_integration_event.yojson_of_t
  in
  let publish_reservation_drawn_down =
    produce ~uri:"in-memory://account.reservation-drawn-down"
      ~yojson_of:
        Account_integration_events.Reservation_drawn_down_integration_event.yojson_of_t
  in
  let dispatch_reserve cmd =
    match
      Account_commands.Reserve_command_workflow.execute ~portfolio:portfolio_ref
        ~next_reservation_id ~slippage_buffer:(Decimal.of_string "0.005")
        ~fee_rate:(Decimal.of_string "0.0005") ~margin_policy ~mark
        ~publish_amount_reserved ~publish_reservation_rejected cmd
    with
    | Ok () -> ()
    (* Business-rule failures already surfaced as
       Reservation_rejected integration event by the workflow; the
       Rop tail is discarded. *)
    | Error _ -> ()
  in
  let dispatch_release (cmd : Account_commands.Release_command.t) =
    match
      Account_commands.Release_command_workflow.execute ~portfolio:portfolio_ref
        ~publish_reservation_released cmd
    with
    | Ok () -> ()
    (* Idempotent compensation: a duplicated or late rejection event
       for a reservation that has already been released is silently
       dropped. *)
    | Error _ -> ()
  in
  let dispatch_commit_fill (cmd : Account_commands.Commit_fill_command.t) =
    match
      Account_commands.Commit_fill_command_workflow.execute ~portfolio:portfolio_ref
        ~publish_reservation_drawn_down ~publish_reservation_filled cmd
    with
    | Ok () -> ()
    (* Two typed errors surface here:
       - [Reservation_not_found]: dropped silently, same
         compensation-idempotency policy as [account.release-command]
         above (a duplicated or late fill against a reservation
         already drained or released is a no-op).
       - [Overfill]: the broker reported a fill quantity exceeding
         the reservation's remaining; today dropped silently, future
         reconcile work may surface it. *)
    | Error _ -> ()
  in
  let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  (* All cross-BC interactions with Account go through the
     order_management saga (per ADR 0022). Account subscribes to:
     - account.reserve-command       — Reserve (saga start)
     - account.release-command       — Release (saga terminal cancel/fail)
     - account.commit-fill-command   — Commit_fill (per ticket fill)
     Broker IEs are EM-internal and Account no longer subscribes to
     them directly. *)
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.reserve-command" ~group:"account-saga"
         ~t_of_yojson:Account_commands.Reserve_command.t_of_yojson)
      dispatch_reserve
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.release-command" ~group:"account-saga"
         ~t_of_yojson:Account_commands.Release_command.t_of_yojson)
      dispatch_release
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.commit-fill-command" ~group:"account-saga"
         ~t_of_yojson:Account_commands.Commit_fill_command.t_of_yojson)
      dispatch_commit_fill
  in
  let http_handler =
    Account_inbound_http.Http.make_handler ~dispatch_reserve ~market_price
  in
  let portfolio_snapshot () = !portfolio_ref in
  { http_handler; portfolio_snapshot }
