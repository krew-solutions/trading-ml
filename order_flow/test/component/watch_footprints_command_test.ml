(** BDD specification for the footprint-subscription command — the
    order_flow analogue of broker's watch_bars_command.

    A caller declares interest in footprints for an [(instrument, boundary)]
    and the command validates the wire primitives and forwards the parsed
    interest to the demand registry's [watch] / [unwatch] port. Expressed in
    terms of intent and observable facts: a watch registers exactly that
    instrument and boundary; a volume boundary is accepted as readily as a
    timeframe; a malformed boundary is refused and registers nothing; an
    unwatch releases the same key. No registry internals leak into the step
    text — the port call is the observable effect. *)

module Gherkin = Gherkin_edsl
module Watch_wf = Order_flow_commands.Watch_footprints_command_workflow
module Watch_h = Order_flow_commands.Watch_footprints_command_handler
module Unwatch_wf = Order_flow_commands.Unwatch_footprints_command_workflow
module Unwatch_h = Order_flow_commands.Unwatch_footprints_command_handler
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary

let key_of ~instrument ~boundary =
  (Core.Instrument.to_qualified instrument, Bar_boundary.to_token boundary)

(* --- Watch --- *)

type wctx = {
  calls : (string * string) list ref;
  last : (unit, Watch_h.handle_error) Rop.t option;
}

let wfresh () = { calls = ref []; last = None }

let watch ctx ~symbol ~boundary =
  let watch ~instrument ~boundary =
    ctx.calls := key_of ~instrument ~boundary :: !(ctx.calls)
  in
  let cmd : Order_flow_commands.Watch_footprints_command.t = { symbol; boundary } in
  { ctx with last = Some (Watch_wf.execute ~watch cmd) }

let registered ctx = List.rev !(ctx.calls)

let watching_a_timeframe_registers_that_key =
  Gherkin.scenario
    "Watching a footprint timeframe registers exactly that instrument and boundary" wfresh
    [
      Gherkin.given "no footprint interest yet" (fun ctx -> ctx);
      Gherkin.when_ "a caller watches SBER@MISX at M1" (fun ctx ->
          watch ctx ~symbol:"SBER@MISX" ~boundary:"M1");
      Gherkin.then_ "the command is accepted" (fun ctx ->
          match ctx.last with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
      Gherkin.then_ "exactly that (instrument, boundary) is registered" (fun ctx ->
          Alcotest.(check (list (pair string string)))
            "registered keys"
            [ ("SBER@MISX", "M1") ]
            (registered ctx));
    ]

let a_volume_boundary_is_accepted =
  Gherkin.scenario "A volume boundary is watched as readily as a timeframe" wfresh
    [
      Gherkin.given "no footprint interest yet" (fun ctx -> ctx);
      Gherkin.when_ "a caller watches SBER@MISX at a 10000-lot volume boundary"
        (fun ctx -> watch ctx ~symbol:"SBER@MISX" ~boundary:"VOL:10000");
      Gherkin.then_ "the command is accepted and the volume key is registered" (fun ctx ->
          (match ctx.last with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
          Alcotest.(check (list (pair string string)))
            "registered keys"
            [ ("SBER@MISX", "VOL:10000") ]
            (registered ctx));
    ]

let a_malformed_boundary_is_refused =
  Gherkin.scenario "A malformed boundary token is refused and registers nothing" wfresh
    [
      Gherkin.given "no footprint interest yet" (fun ctx -> ctx);
      Gherkin.when_
        "a caller watches with a boundary that is neither a timeframe nor VOL:<n>"
        (fun ctx -> watch ctx ~symbol:"SBER@MISX" ~boundary:"NOPE");
      Gherkin.then_ "the command is refused, naming the bad boundary" (fun ctx ->
          match ctx.last with
          | Some (Error errs) ->
              let named =
                List.exists
                  (function
                    | Watch_h.Validation (Watch_h.Invalid_boundary "NOPE") -> true
                    | _ -> false)
                  errs
              in
              Alcotest.(check bool) "invalid boundary reported" true named
          | _ -> Alcotest.fail "expected a refusal");
      Gherkin.then_ "nothing is registered" (fun ctx ->
          Alcotest.(check int) "registered count" 0 (List.length (registered ctx)));
    ]

(* --- Unwatch --- *)

type uctx = {
  releases : (string * string) list ref;
  last : (unit, Unwatch_h.handle_error) Rop.t option;
}

let ufresh () = { releases = ref []; last = None }

let unwatch ctx ~symbol ~boundary =
  let unwatch ~instrument ~boundary =
    ctx.releases := key_of ~instrument ~boundary :: !(ctx.releases)
  in
  let cmd : Order_flow_commands.Unwatch_footprints_command.t = { symbol; boundary } in
  { ctx with last = Some (Unwatch_wf.execute ~unwatch cmd) }

let unwatching_releases_the_same_key =
  Gherkin.scenario "Unwatching releases the same instrument and boundary" ufresh
    [
      Gherkin.given "no release yet" (fun ctx -> ctx);
      Gherkin.when_ "a caller unwatches SBER@MISX at M1" (fun ctx ->
          unwatch ctx ~symbol:"SBER@MISX" ~boundary:"M1");
      Gherkin.then_ "the command is accepted and that key is released" (fun ctx ->
          (match ctx.last with
          | Some (Ok ()) -> ()
          | _ -> Alcotest.fail "expected acceptance");
          Alcotest.(check (list (pair string string)))
            "released keys"
            [ ("SBER@MISX", "M1") ]
            (List.rev !(ctx.releases)));
    ]

let feature =
  Gherkin.feature "Watch/unwatch footprints command"
    [
      watching_a_timeframe_registers_that_key;
      a_volume_boundary_is_accepted;
      a_malformed_boundary_is_refused;
      unwatching_releases_the_same_key;
    ]
