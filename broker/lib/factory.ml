open Core

type rest = Finam of Finam.Rest.t | Bcs of Bcs.Rest.t | Synthetic

type t = {
  client : Broker.client;
  paper_broker : Paper.Paper_broker.t option;
  market_price : instrument:Instrument.t -> Decimal.t;
  ws_setup : (sw:Eio.Switch.t -> Server.Http.live_setup) option;
  http_handler : Inbound_http.Route.handler;
}

(** Build a {!Server.Http.live_setup} that bridges Finam's WebSocket
    feed into the SSE stream registry and into the bar-updated bus
    publisher. Connection happens up-front on the server's switch;
    per-key SUBSCRIBE/UNSUBSCRIBE messages flow on subscriber
    lifecycle hooks; inbound BARS events fan out via
    [Stream.push_from_upstream] and [publish_bar_updated]. *)
let finam_live_setup ~env ~paper_sink ~publish_bar_updated (rest : Finam.Rest.t) ~sw :
    Server.Http.live_setup =
  let cfg = Finam.Rest.cfg rest in
  let auth = Finam.Rest.auth rest in
  let registry_ref : Server.Stream.t option ref = ref None in
  (* Forward-declared to break the mutual dependency: the bridge's
     event handler needs to know the bridge to look up active
     timeframes, so we close over a ref that gets set right after
     [make] returns. *)
  let bridge_ref : Finam.Ws_bridge.bridge option ref = ref None in
  let on_event (ev : Finam.Ws.event) =
    match ev with
    | Bars { instrument; timeframe; bars } ->
        List.iter (fun candle -> paper_sink instrument candle) bars;
        let tfs : Timeframe.t list =
          match timeframe with
          | Some tf -> [ tf ]
          | None -> (
              (* No subscription_key in the frame — fall back to the
                 legacy scan of active subs for this instrument. *)
              match !bridge_ref with
              | None -> []
              | Some b -> Finam.Ws_bridge.timeframes_for_instrument b instrument)
        in
        List.iter
          (fun (tf : Timeframe.t) ->
            List.iter
              (fun (candle : Candle.t) ->
                (match !registry_ref with
                | Some r ->
                    Server.Stream.push_from_upstream r ~instrument ~timeframe:tf candle
                | None -> ());
                publish_bar_updated
                  (Broker_integration_events.Bar_updated_integration_event.of_domain
                     ~instrument ~timeframe:tf ~bar:candle))
              bars)
          tfs
    | Error_ev { code; type_; message } ->
        Log.warn "[finam ws] error %d %s: %s" code type_ message
    | Lifecycle { event; code; reason } ->
        Log.info "[finam ws] %s (%d) %s" event code reason
    | _ -> ()
  in
  let bridge = Finam.Ws_bridge.make ~env ~sw ~cfg ~auth ~on_event in
  bridge_ref := Some bridge;
  Server.Http.
    {
      on_first =
        (fun ~instrument ~timeframe ->
          try Finam.Ws_bridge.subscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[finam ws] subscribe failed: %s" (Printexc.to_string e));
      on_last =
        (fun ~instrument ~timeframe ->
          try Finam.Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[finam ws] unsubscribe failed: %s" (Printexc.to_string e));
      bind = (fun r -> registry_ref := Some r);
    }

(** Build a {!Server.Http.live_setup} for BCS. Unlike Finam, BCS
    opens one socket per subscription, so the bridge defers connect
    to [on_first] and tears down on [on_last]. The BARS fan-out
    callback pushes directly into the registry via
    [Stream.push_from_upstream] and into [publish_bar_updated]. *)
let bcs_live_setup ~env ~paper_sink ~publish_bar_updated (rest : Bcs.Rest.t) ~sw :
    Server.Http.live_setup =
  let cfg = Bcs.Rest.cfg rest in
  let auth = Bcs.Rest.auth rest in
  let bridge = Bcs.Ws_bridge.make ~env ~sw ~cfg ~auth in
  let registry_ref : Server.Stream.t option ref = ref None in
  let push instrument timeframe candle =
    paper_sink instrument candle;
    (match !registry_ref with
    | Some r -> Server.Stream.push_from_upstream r ~instrument ~timeframe candle
    | None -> ());
    publish_bar_updated
      (Broker_integration_events.Bar_updated_integration_event.of_domain ~instrument
         ~timeframe ~bar:candle)
  in
  Server.Http.
    {
      on_first =
        (fun ~instrument ~timeframe ->
          try Bcs.Ws_bridge.subscribe_bars bridge ~instrument ~timeframe ~on_candle:push
          with e -> Log.warn "[bcs ws] subscribe failed: %s" (Printexc.to_string e));
      on_last =
        (fun ~instrument ~timeframe ->
          try Bcs.Ws_bridge.unsubscribe_bars bridge ~instrument ~timeframe
          with e -> Log.warn "[bcs ws] unsubscribe failed: %s" (Printexc.to_string e));
      bind = (fun r -> registry_ref := Some r);
    }

let build ~bus ~env ~source_client ~rest ~paper_mode : t =
  let paper_broker =
    if paper_mode then Some (Paper.Paper_broker.make ~source:source_client ()) else None
  in
  let client =
    match paper_broker with
    | Some p -> Paper.Paper_broker.as_broker p
    | None -> source_client
  in
  let market_price ~instrument =
    match Broker.bars client ~n:1 ~instrument ~timeframe:Timeframe.H1 with
    | last :: _ -> last.close
    | [] -> Decimal.zero
  in
  let paper_sink =
    match paper_broker with
    | Some p -> fun instrument candle -> Paper.Paper_broker.on_bar p ~instrument candle
    | None -> fun _ _ -> ()
  in
  let produce (type a) ~uri ~(yojson_of : a -> Yojson.Safe.t) : a -> unit =
    Bus.publish
      (Bus.producer bus ~uri ~serialize:(fun v -> Yojson.Safe.to_string (yojson_of v)))
  in
  let publish_order_accepted =
    produce ~uri:"in-memory://broker.order-accepted"
      ~yojson_of:Broker_integration_events.Order_accepted_integration_event.yojson_of_t
  in
  let publish_order_rejected =
    produce ~uri:"in-memory://broker.order-rejected"
      ~yojson_of:Broker_integration_events.Order_rejected_integration_event.yojson_of_t
  in
  let publish_order_unreachable =
    produce ~uri:"in-memory://broker.order-unreachable"
      ~yojson_of:Broker_integration_events.Order_unreachable_integration_event.yojson_of_t
  in
  let publish_bar_updated =
    produce ~uri:"in-memory://broker.bar-updated"
      ~yojson_of:Broker_integration_events.Bar_updated_integration_event.yojson_of_t
  in
  let _dispatch_submit_order =
    Broker_commands.Submit_order_command_handler.make ~broker:client
      ~publish_accepted:publish_order_accepted ~publish_rejected:publish_order_rejected
      ~publish_unreachable:publish_order_unreachable
  in
  (* Built and held in scope for end-to-end typecheck of the
     Submit_order pipeline. The future place-order saga will replace
     this throwaway binding with a [Bus.subscribe] on
     [account.amount-reserved] whose callback translates the inbound
     IE into a [Submit_order_command] and invokes the dispatcher
     captured in its closure. The dispatcher does not leak through
     [t] because no consumer outside this factory needs it. *)
  let ws_setup =
    match rest with
    | Finam r -> Some (finam_live_setup ~env ~paper_sink ~publish_bar_updated r)
    | Bcs r -> Some (bcs_live_setup ~env ~paper_sink ~publish_bar_updated r)
    | Synthetic -> None
  in
  let http_handler = Broker_inbound_http.Http.make_handler ~broker:client in
  { client; paper_broker; market_price; ws_setup; http_handler }
