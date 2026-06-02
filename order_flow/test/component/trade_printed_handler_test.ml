(** BDD specification for the inbound ACL: public-tape prints relayed
    from the broker BC drive footprints through the order_flow workflow.

    Exercises the Anti-corruption boundary — an external
    Trade_printed integration event is translated into the BC's own
    ingest_print command and run in-process — and confirms the ACL is
    idempotent: a malformed relayed print is absorbed, not propagated. *)

module Gherkin = Gherkin_edsl

module Handler =
  Order_flow_external_integration_events.Public_trade_printed_integration_event_handler

module Ext = Order_flow_external_integration_events.Public_trade_printed_integration_event
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary
module Timeframe = Core.Timeframe
module Footprint = Order_flow.Footprint
module FC = Order_flow_integration_events.Footprint_completed_integration_event

type ctx = {
  store : (string * string, Footprint.t) Hashtbl.t;
      (** keyed by (Instrument.to_qualified, Bar_boundary.to_token) *)
  pub : FC.t list ref;
  boundaries : Bar_boundary.t list;
      (** boundaries the demand registry would report for the instrument *)
}

let fresh () =
  {
    store = Hashtbl.create 8;
    pub = ref [];
    boundaries = [ Bar_boundary.Time Core.Timeframe.M5 ];
  }

let slot inst b = (Core.Instrument.to_qualified inst, Bar_boundary.to_token b)

let relay ctx ~price ~size ~ts ~aggressor =
  let ie : Ext.t = { symbol = "SBER@MISX"; price; size; ts; aggressor } in
  let get_bar inst b = Hashtbl.find_opt ctx.store (slot inst b) in
  let put_bar inst b bar = Hashtbl.replace ctx.store (slot inst b) bar in
  Handler.handle
    ~boundaries_for:(fun _symbol -> ctx.boundaries)
    ~get_bar ~put_bar
    ~publish_footprint_completed:(fun e -> ctx.pub := e :: !(ctx.pub))
    ie;
  ctx

let t0 = "2024-01-15T10:00:00Z"
let t1 = "2024-01-15T10:02:00Z"
let t_next = "2024-01-15T10:05:30Z"

let relayed_prints_drive_the_footprint =
  Gherkin.scenario "Public-tape prints relayed from the broker drive the footprint" fresh
    [
      Gherkin.given "two prints in one bucket arrive over the ACL" (fun ctx ->
          ctx
          |> relay ~price:"100" ~size:"5" ~ts:t0 ~aggressor:"BUY"
          |> relay ~price:"101" ~size:"3" ~ts:t1 ~aggressor:"SELL");
      Gherkin.when_ "a print for the next bucket arrives" (fun ctx ->
          ctx |> relay ~price:"100" ~size:"1" ~ts:t_next ~aggressor:"BUY");
      Gherkin.then_
        "one completed footprint is announced with the bucket's volume and delta"
        (fun ctx ->
          match !(ctx.pub) with
          | [ ie ] ->
              Alcotest.(check string) "volume" "8" ie.FC.volume;
              Alcotest.(check string) "delta" "2" ie.FC.delta
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one completed footprint, got %d"
                   (List.length other)));
    ]

let malformed_relayed_print_is_absorbed =
  Gherkin.scenario "A malformed relayed print is absorbed by the ACL, announcing nothing"
    fresh
    [
      Gherkin.given "no bar in progress" (fun ctx -> ctx);
      Gherkin.when_ "a print with a non-positive size is relayed" (fun ctx ->
          ctx |> relay ~price:"100" ~size:"0" ~ts:t0 ~aggressor:"BUY");
      Gherkin.then_ "nothing is announced and no error escapes the ACL" (fun ctx ->
          Alcotest.(check int) "completed count" 0 (List.length !(ctx.pub)));
    ]

(* A second timeframe is watched alongside the default — the demand-driven
   case: one relayed print stream must build footprints at every watched
   boundary independently, each on its own clock. *)
let t_m1_roll = "2024-01-15T10:01:30Z"

let one_tape_feeds_every_watched_boundary =
  Gherkin.scenario
    "One relayed tape builds a footprint at every watched boundary, each on its own clock"
    (fun () ->
      {
        (fresh ()) with
        boundaries = [ Bar_boundary.Time Timeframe.M5; Bar_boundary.Time Timeframe.M1 ];
      })
    [
      Gherkin.given "M5 and M1 are both watched for the instrument" (fun ctx -> ctx);
      Gherkin.when_
        "prints cross the M1 minute boundary and then the M5 five-minute boundary"
        (fun ctx ->
          ctx
          (* 10:00:00 — opens the 10:00 bar under both boundaries *)
          |> relay ~price:"100" ~size:"5" ~ts:t0 ~aggressor:"BUY"
          (* 10:01:30 — new M1 minute: seals M1[10:00]=5, M5 still forming *)
          |> relay ~price:"101" ~size:"3" ~ts:t_m1_roll ~aggressor:"BUY"
          (* 10:05:30 — new M5 bucket and new M1 minute: seals M5[10:00]=8
             and M1[10:01]=3 *)
          |> relay ~price:"100" ~size:"1" ~ts:t_next ~aggressor:"BUY");
      Gherkin.then_ "the M5 footprint is announced exactly once, carrying the M5 volume"
        (fun ctx ->
          let m5 = List.filter (fun ie -> ie.FC.timeframe = "M5") !(ctx.pub) in
          match m5 with
          | [ ie ] -> Alcotest.(check string) "M5 volume" "8" ie.FC.volume
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one M5 footprint, got %d" (List.length other)));
      Gherkin.then_ "the M1 footprints are announced independently, one per sealed minute"
        (fun ctx ->
          let m1 = List.filter (fun ie -> ie.FC.timeframe = "M1") !(ctx.pub) in
          Alcotest.(check int) "M1 footprint count" 2 (List.length m1);
          let vols = List.sort compare (List.map (fun ie -> ie.FC.volume) m1) in
          Alcotest.(check (list string)) "M1 volumes (10:00=5, 10:01=3)" [ "3"; "5" ] vols);
    ]

let feature =
  Gherkin.feature "Trade printed (broker tape) ACL"
    [
      relayed_prints_drive_the_footprint;
      malformed_relayed_print_is_absorbed;
      one_tape_feeds_every_watched_boundary;
    ]
