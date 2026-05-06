type t = {
  http_handler : Inbound_http.Route.handler;
  on_fill_event : (Live_engine.fill_event -> unit) option;
}

let build ~bus ~sw ~broker ~strategy ~engine_symbol : t =
  let http_handler = Strategy_inbound_http.Http.make_handler () in
  match strategy with
  | None -> { http_handler; on_fill_event = None }
  | Some strat ->
      let equity = Decimal.of_int 1_000_000 in
      let cfg : Live_engine.config =
        {
          broker;
          strategy = strat;
          instrument = engine_symbol;
          initial_cash = equity;
          limits = Engine.Risk.default_limits ~equity;
          tif = Order.DAY;
          fee_rate = Decimal.of_string "0.0005";
          reconcile_every = 10;
          max_drawdown_pct = 0.15;
          rate_limit = None;
        }
      in
      let engine = Live_engine.make cfg in
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
      { http_handler; on_fill_event = Some (Live_engine.on_fill_event engine) }
