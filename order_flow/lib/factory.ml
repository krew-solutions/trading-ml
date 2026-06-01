open Core

(** Composition unit for the order_flow BC (ADR 0032).

    Holds the per-instrument forming-bar store (transitional in-memory
    persistence) and subscribes the inbound ACL to the broker's public
    tape on [broker.public-trade-printed]; sealed footprints are published on
    [order-flow.footprint-completed] for the strategy BC to consume.

    No clock dependency: a print carries its own venue timestamp, and the
    Time-bar boundary closes lazily on the first print of the next bucket
    (the clock-driven idle-flush is a deferred refinement, ADR 0032). *)

module Trade_printed_ie =
  Order_flow_external_integration_events.Public_trade_printed_integration_event

module Trade_printed_handler =
  Order_flow_external_integration_events.Public_trade_printed_integration_event_handler

module Footprint = Order_flow.Footprint
module Footprint_completed_ie =
  Order_flow_integration_events.Footprint_completed_integration_event
module Footprint_history = Order_flow_inbound_http.Footprint_history

type t = { http_handler : Inbound_http.Route.handler }
(** What the composition root needs from the BC beyond the bus wiring:
    the inbound read route ([GET /api/footprints]) to fold into the
    core HTTP server's handler list. *)

let build ~bus ?(timeframe = Timeframe.M5) ?boundary () : t =
  (* Forming bar per instrument, keyed by qualified symbol. *)
  let store : (string, Footprint.t) Hashtbl.t = Hashtbl.create 64 in
  let get_bar instrument = Hashtbl.find_opt store (Instrument.to_qualified instrument) in
  let put_bar instrument bar =
    Hashtbl.replace store (Instrument.to_qualified instrument) bar
  in
  (* [?boundary] overrides the default explicitly — e.g.
     [Bar_boundary.Volume (Decimal.of_int 10_000)] — without the
     composition root touching anything else (ADR 0032 §5). *)
  let boundary =
    match boundary with
    | Some b -> b
    | None -> Footprint.Values.Bar_boundary.Time timeframe
  in
  (* Read-model of recently sealed footprints, fed from this BC's own
     footprint-completed stream — the pull side of [GET /api/footprints],
     a peer of the push side that publishes the same fact onward. *)
  let history = Footprint_history.create () in
  let producer =
    Bus.producer bus ~uri:"in-memory://order-flow.footprint-completed"
      ~serialize:(fun v -> Yojson.Safe.to_string (Footprint_completed_ie.yojson_of_t v))
  in
  let publish_footprint_completed (ie : Footprint_completed_ie.t) =
    (* Record into the read-model before publishing onward: the query
       sees a sealed footprint no later than its downstream consumers. *)
    Footprint_history.record history ie;
    Bus.publish producer ie
  in
  let consumer =
    Bus.consumer bus ~uri:"in-memory://broker.public-trade-printed"
      ~group:"order-flow-ingest" ~deserialize:(fun s ->
        Trade_printed_ie.t_of_yojson (Yojson.Safe.from_string s))
  in
  let (_ : Bus.subscription) =
    Bus.subscribe consumer
      (Trade_printed_handler.handle ~boundary ~get_bar ~put_bar
         ~publish_footprint_completed)
  in
  { http_handler = Order_flow_inbound_http.Http.make_handler ~history }
