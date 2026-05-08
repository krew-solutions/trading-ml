type t = { http_handler : Inbound_http.Route.handler }

let build ~bus ~sw ~strategy ~strategy_id ~engine_symbol : t =
  let http_handler = Strategy_inbound_http.Http.make_handler () in
  match strategy with
  | None -> { http_handler }
  | Some strat ->
      let publish_signal_detected =
        Bus.publish
          (Bus.producer bus ~uri:"in-memory://strategy.signal-detected"
             ~serialize:(fun v ->
               Yojson.Safe.to_string
                 (Strategy_integration_events.Signal_detected_integration_event
                  .yojson_of_t v)))
      in
      let cfg : Live_engine.config =
        { strategy = strat; instrument = engine_symbol; strategy_id }
      in
      let engine = Live_engine.make ~config:cfg ~publish_signal_detected in
      let engine_handler =
        Strategy_inbound_integration_events.Bar_updated_integration_event_handler.make
          ~capacity:64
      in
      let consumer =
        Bus.consumer bus ~uri:"in-memory://broker.bar-updated" ~group:"strategy-engine"
          ~deserialize:(fun s ->
            Strategy_inbound_integration_events.Bar_updated_integration_event.t_of_yojson
              (Yojson.Safe.from_string s))
      in
      let _ : Bus.subscription =
        Bus.subscribe consumer
          (Strategy_inbound_integration_events.Bar_updated_integration_event_handler
           .handle engine_handler ~instrument:engine_symbol)
      in
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Live_engine.run engine
            ~source:
              (Strategy_inbound_integration_events.Bar_updated_integration_event_handler
               .source engine_handler);
          `Stop_daemon);
      { http_handler }
