type t = { http_handler : Inbound_http.Route.handler }

type config = {
  initial_equity : Decimal.t;
  max_drawdown_pct : float;
  rate_limit : (int * float) option;
}

let build ~bus ~now ~(config : config) : t =
  let mu = Mutex.create () in
  let with_lock f =
    Mutex.lock mu;
    Fun.protect ~finally:(fun () -> Mutex.unlock mu) f
  in
  let limits = Pre_trade_risk.Risk_limits.default ~equity:config.initial_equity in
  let kill_switch =
    ref
      (Pre_trade_risk.Kill_switch.make ~initial_equity:config.initial_equity
         ~max_drawdown_pct:
           (Pre_trade_risk.Kill_switch.Values.Max_drawdown_pct.of_float
              config.max_drawdown_pct))
  in
  let rate_limit =
    ref
      (match config.rate_limit with
      | Some (max_orders, window_seconds) ->
          Some
            (Pre_trade_risk.Rate_limit.make
               ~config:
                 (Pre_trade_risk.Rate_limit.Values.Rate_limit_config.make ~max_orders
                    ~window_seconds))
      | None -> None)
  in
  let now_iso8601 () = Datetime.Iso8601.format (now ()) in
  (* Per-book Risk_view aggregates. Created on-demand on first event /
     query for a book; same lazy pattern as PM. *)
  let views : (string, Pre_trade_risk.Risk_view.t ref) Hashtbl.t = Hashtbl.create 8 in
  let risk_view_ref_for (bid : Pre_trade_risk.Common.Book_id.t) =
    let key = Pre_trade_risk.Common.Book_id.to_string bid in
    match Hashtbl.find_opt views key with
    | Some r -> r
    | None ->
        let r = ref (Pre_trade_risk.Risk_view.empty bid) in
        Hashtbl.add views key r;
        r
  in
  let risk_view_for (bid : Pre_trade_risk.Common.Book_id.t) =
    let key = Pre_trade_risk.Common.Book_id.to_string bid in
    Option.map ( ! ) (Hashtbl.find_opt views key)
  in
  let mark : Core.Instrument.t -> Decimal.t option = fun _ -> None in
  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
  in
  let publish_approved =
    produce ~uri:"in-memory://pre-trade-risk.trade-intent-approved"
      ~yojson_of:
        Pre_trade_risk_integration_events.Trade_intent_approved_integration_event
        .yojson_of_t
  in
  let publish_rejected =
    produce ~uri:"in-memory://pre-trade-risk.trade-intent-rejected"
      ~yojson_of:
        Pre_trade_risk_integration_events.Trade_intent_rejected_integration_event
        .yojson_of_t
  in
  let publish_blocked =
    produce ~uri:"in-memory://pre-trade-risk.trade-submission-blocked"
      ~yojson_of:
        Pre_trade_risk_integration_events.Trade_submission_blocked_integration_event
        .yojson_of_t
  in
  let publish_kill_switch_tripped =
    produce ~uri:"in-memory://pre-trade-risk.kill-switch-tripped"
      ~yojson_of:
        Pre_trade_risk_integration_events.Kill_switch_tripped_integration_event
        .yojson_of_t
  in
  (* Gate check at intake. [Allow] consumes a rate_limit token as a
     side-effect; [Block reason] leaves the gate state untouched. *)
  let try_intake ~now_secs : [ `Allow | `Block of string ] =
    if Pre_trade_risk.Kill_switch.is_halted !kill_switch then `Block "kill_switch"
    else
      match !rate_limit with
      | None -> `Allow
      | Some rl -> (
          match Pre_trade_risk.Rate_limit.try_acquire rl ~now:now_secs with
          | `Allow rl' ->
              rate_limit := Some rl';
              `Allow
          | `Throttle -> `Block "rate_limit")
  in
  let dispatch_assess (cmd : Pre_trade_risk_commands.Assess_trade_intent_command.t) =
    with_lock (fun () ->
        let now_secs = Int64.to_float (now ()) in
        match try_intake ~now_secs with
        | `Block reason ->
            publish_blocked
              {
                correlation_id = cmd.correlation_id;
                reason;
                occurred_at = now_iso8601 ();
              }
        | `Allow -> (
            match
              Pre_trade_risk_commands.Assess_trade_intent_command_workflow.execute
                ~risk_view_for ~limits ~mark ~publish_approved ~publish_rejected cmd
            with
            | Ok () -> ()
            | Error _ -> ()))
  in
  let dispatch_record_fill cmd =
    match
      Pre_trade_risk_commands.Record_fill_command_workflow.execute ~risk_view_ref_for cmd
    with
    | Ok () -> ()
    | Error _ -> ()
  in
  let consume (type a) ~uri ~group ~(t_of_yojson : Yojson.Safe.t -> a) : a Bus.consumer =
    Bus.consumer bus ~uri ~group ~deserialize:(fun s ->
        t_of_yojson (Yojson.Safe.from_string s))
  in
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://pm.trade-intents-planned" ~group:"pre-trade-risk-assess"
         ~t_of_yojson:
           Pre_trade_risk_external_integration_events
           .Trade_intents_planned_integration_event
           .t_of_yojson)
      (Pre_trade_risk_external_integration_events
       .Trade_intents_planned_integration_event_handler
       .handle ~risk_view_for ~dispatch_assess)
  in
  (* Reservation_filled drives two things: the per-fill Risk_view
     commit (positions / cash), and the Kill_switch peak / drawdown
     tracking. The trip event surfaces once, the first time the
     threshold is crossed. *)
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.reservation-filled"
         ~group:"pre-trade-risk-fill-commit"
         ~t_of_yojson:
           Pre_trade_risk_external_integration_events.Reservation_filled_integration_event
           .t_of_yojson)
      (fun
        (ev :
          Pre_trade_risk_external_integration_events.Reservation_filled_integration_event
          .t)
      ->
        Pre_trade_risk_external_integration_events
        .Reservation_filled_integration_event_handler
        .handle ~now ~dispatch_record_fill ev;
        with_lock (fun () ->
            let equity = try Decimal.of_string ev.new_cash with _ -> Decimal.zero in
            let occurred_at = now () in
            let ks', tripped =
              Pre_trade_risk.Kill_switch.update_equity !kill_switch ~equity ~occurred_at
            in
            kill_switch := ks';
            match tripped with
            | None -> ()
            | Some ev_t ->
                publish_kill_switch_tripped
                  {
                    peak_equity = Decimal.to_string ev_t.peak_equity;
                    current_equity = Decimal.to_string ev_t.current_equity;
                    drawdown = ev_t.drawdown;
                    occurred_at = Datetime.Iso8601.format ev_t.occurred_at;
                  }))
  in
  let http_handler = Pre_trade_risk_inbound_http.Http.make_handler () in
  { http_handler }
