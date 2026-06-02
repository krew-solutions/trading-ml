open Core

(** Composition unit for the order_flow BC (ADR 0032).

    Holds the per-[(instrument, boundary)] forming-bar store (transitional
    in-memory persistence) and subscribes the inbound ACL to the broker's
    public tape on [broker.public-trade-printed]; sealed footprints are
    published on [order-flow.footprint-completed] for the strategy BC to
    consume.

    Footprints are demand-driven: each print is fanned into the operator's
    default boundary (always on) plus any boundary a caller has watched via
    [order-flow.watch-footprints-command] — the footprint analogue of
    broker's watch-bars-command, refcounted per [(instrument, boundary)]
    so a UI can subscribe to a footprint timeframe of its own choosing.

    No clock dependency: a print carries its own venue timestamp, and the
    Time-bar boundary closes lazily on the first print of the next bucket
    (the clock-driven idle-flush is a deferred refinement, ADR 0032). *)

module Trade_printed_ie =
  Order_flow_external_integration_events.Public_trade_printed_integration_event

module Trade_printed_handler =
  Order_flow_external_integration_events.Public_trade_printed_integration_event_handler

module Footprint = Order_flow.Footprint
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary
module Footprint_completed_ie =
  Order_flow_integration_events.Footprint_completed_integration_event
module Footprint_history = Order_flow_inbound_http.Footprint_history
module Watch_footprints_command = Order_flow_commands.Watch_footprints_command
module Watch_footprints_workflow = Order_flow_commands.Watch_footprints_command_workflow
module Unwatch_footprints_command = Order_flow_commands.Unwatch_footprints_command
module Unwatch_footprints_workflow =
  Order_flow_commands.Unwatch_footprints_command_workflow

type t = { http_handler : Inbound_http.Route.handler }
(** What the composition root needs from the BC beyond the bus wiring:
    the inbound read route ([GET /api/footprints]) to fold into the
    core HTTP server's handler list. *)

let build ~bus ?(timeframe = Timeframe.M5) ?boundary () : t =
  (* Forming bar per [(instrument, boundary)], keyed by the qualified
     symbol paired with the boundary token. A single instrument can have
     several boundaries forming at once (the configured default plus any a
     UI has watched), each an independent aggregate in its own slot. *)
  let store : (string * string, Footprint.t) Hashtbl.t = Hashtbl.create 64 in
  let slot instrument boundary =
    (Instrument.to_qualified instrument, Bar_boundary.to_token boundary)
  in
  let get_bar instrument boundary = Hashtbl.find_opt store (slot instrument boundary) in
  let put_bar instrument boundary bar =
    Hashtbl.replace store (slot instrument boundary) bar
  in
  (* [?boundary] overrides the default explicitly — e.g.
     [Bar_boundary.Volume (Decimal.of_int 10_000)] — without the
     composition root touching anything else (ADR 0032 §5). *)
  let default_boundary =
    match boundary with
    | Some b -> b
    | None -> Bar_boundary.Time timeframe
  in
  let default_token = Bar_boundary.to_token default_boundary in
  (* Demand registry: which boundaries are watched per instrument, refcounted
     so concurrent watchers on the same key coexist and a boundary stops
     forming only when the last watcher drops it (mirrors broker's
     adapter-side refcount for bar feeds). Keyed by qualified symbol -> token
     -> count. Single Eio domain: the trade-tape consumer reads it while the
     watch/unwatch consumers write it, but every access is a synchronous
     Hashtbl operation with no fibre yield inside, so no lock is needed —
     same discipline as [store]. *)
  let watched : (string, (string, int) Hashtbl.t) Hashtbl.t = Hashtbl.create 64 in
  let watch ~instrument ~boundary =
    let sym = Instrument.to_qualified instrument in
    let tok = Bar_boundary.to_token boundary in
    let inner =
      match Hashtbl.find_opt watched sym with
      | Some h -> h
      | None ->
          let h = Hashtbl.create 4 in
          Hashtbl.replace watched sym h;
          h
    in
    let prev = Option.value ~default:0 (Hashtbl.find_opt inner tok) in
    Hashtbl.replace inner tok (prev + 1)
  in
  let unwatch ~instrument ~boundary =
    let sym = Instrument.to_qualified instrument in
    let tok = Bar_boundary.to_token boundary in
    match Hashtbl.find_opt watched sym with
    | None -> ()
    | Some inner -> (
        match Hashtbl.find_opt inner tok with
        | None | Some 1 ->
            Hashtbl.remove inner tok;
            if Hashtbl.length inner = 0 then Hashtbl.remove watched sym
        | Some n -> Hashtbl.replace inner tok (n - 1))
  in
  (* Boundaries to fan a print into for [symbol]: the configured default
     (always on — preserves the headless behaviour) plus every watched
     boundary, deduplicated by token so a watch of the default does not
     double-ingest. Tokens were produced by [to_token], so [of_token] round
     trips; the filter is defensive only. *)
  let boundaries_for (symbol : string) : Bar_boundary.t list =
    let watched_tokens =
      match Hashtbl.find_opt watched symbol with
      | None -> []
      | Some inner ->
          Hashtbl.fold (fun tok n acc -> if n > 0 then tok :: acc else acc) inner []
    in
    default_token :: watched_tokens
    |> List.sort_uniq String.compare
    |> List.filter_map (fun tok ->
        match Bar_boundary.of_token tok with
        | b -> Some b
        | exception _ -> None)
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
      (Trade_printed_handler.handle ~boundaries_for ~get_bar ~put_bar
         ~publish_footprint_completed)
  in
  (* Footprint-subscription commands (the order_flow analogue of broker's
     watch/unwatch-bars-command): a caller declares interest in footprints
     for an [(instrument, boundary)] and the demand registry above starts /
     stops fanning the tape into that boundary. The validation-error list is
     already logged inside each workflow; the dispatcher discards it. *)
  let watch_consumer =
    Bus.consumer bus ~uri:"in-memory://order-flow.watch-footprints-command"
      ~group:"order-flow-footprint-subscription" ~deserialize:(fun s ->
        Watch_footprints_command.t_of_yojson (Yojson.Safe.from_string s))
  in
  let (_ : Bus.subscription) =
    Bus.subscribe watch_consumer (fun cmd ->
        match Watch_footprints_workflow.execute ~watch cmd with
        | Ok () | Error _ -> ())
  in
  let unwatch_consumer =
    Bus.consumer bus ~uri:"in-memory://order-flow.unwatch-footprints-command"
      ~group:"order-flow-footprint-subscription" ~deserialize:(fun s ->
        Unwatch_footprints_command.t_of_yojson (Yojson.Safe.from_string s))
  in
  let (_ : Bus.subscription) =
    Bus.subscribe unwatch_consumer (fun cmd ->
        match Unwatch_footprints_workflow.execute ~unwatch cmd with
        | Ok () | Error _ -> ())
  in
  { http_handler = Order_flow_inbound_http.Http.make_handler ~history }
