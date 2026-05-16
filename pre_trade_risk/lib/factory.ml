type t = { http_handler : Inbound_http.Route.handler }

let build ~bus ~now ~initial_equity : t =
  let limits = Pre_trade_risk.Risk_limits.default ~equity:initial_equity in
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
  (* Marks not yet wired (needs broker.bar-updated subscription, a
     follow-up). Until then, Assessment falls back to
     position.avg_price; opening trades against unheld instruments
     reject with "zero price". *)
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
  let dispatch_assess cmd =
    match
      Pre_trade_risk_commands.Assess_trade_intent_command_workflow.execute ~risk_view_for
        ~limits ~mark ~publish_approved ~publish_rejected cmd
    with
    | Ok () -> ()
    | Error _ -> ()
    (* Validation failure of the inbound command is a contract bug
       upstream; logged elsewhere, no IE emitted by design. *)
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
  let _ : Bus.subscription =
    Bus.subscribe
      (consume ~uri:"in-memory://account.reservation-filled"
         ~group:"pre-trade-risk-fill-commit"
         ~t_of_yojson:
           Pre_trade_risk_external_integration_events.Reservation_filled_integration_event
           .t_of_yojson)
      (Pre_trade_risk_external_integration_events
       .Reservation_filled_integration_event_handler
       .handle ~now ~dispatch_record_fill)
  in
  let http_handler = Pre_trade_risk_inbound_http.Http.make_handler () in
  { http_handler }
