(** BDD specification for the inbound ACL: public-tape prints relayed
    from the broker BC drive footprints through the order_flow workflow.

    Exercises the Anti-corruption boundary — an external
    Trade_printed integration event is translated into the BC's own
    ingest_print command and run in-process — and confirms the ACL is
    idempotent: a malformed relayed print is absorbed, not propagated. *)

module Gherkin = Gherkin_edsl

module Handler =
  Order_flow_external_integration_events.Trade_printed_integration_event_handler

module Ext = Order_flow_external_integration_events.Trade_printed_integration_event
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary
module Footprint = Order_flow.Footprint
module FC = Order_flow_integration_events.Footprint_completed_integration_event

type ctx = { store : (string, Footprint.t) Hashtbl.t; pub : FC.t list ref }

let fresh () = { store = Hashtbl.create 8; pub = ref [] }
let boundary = Bar_boundary.Time Core.Timeframe.M5

let relay ctx ~price ~size ~ts ~aggressor =
  let ie : Ext.t = { symbol = "SBER@MISX"; price; size; ts; aggressor } in
  let get_bar inst = Hashtbl.find_opt ctx.store (Core.Instrument.to_qualified inst) in
  let put_bar inst bar =
    Hashtbl.replace ctx.store (Core.Instrument.to_qualified inst) bar
  in
  Handler.handle ~boundary ~get_bar ~put_bar
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

let feature =
  Gherkin.feature "Trade printed (broker tape) ACL"
    [ relayed_prints_drive_the_footprint; malformed_relayed_print_is_absorbed ]
