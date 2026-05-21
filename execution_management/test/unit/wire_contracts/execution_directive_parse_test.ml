(** Wire-directive parser coverage for
    {!Open_order_ticket_command_handler.resolve_directive}. The
    parser is the boundary between the wire shape (kind tag +
    opaque JSON params blob) and the typed
    {!Order_ticket.Values.Execution_directive.t} the aggregate
    consumes. *)

module Handler = Execution_management_commands.Open_order_ticket_command_handler
module Cmd = Execution_management_commands.Open_order_ticket_command
module Values = Execution_management.Order_ticket.Values
module Cmd_err = Execution_management_commands.Command_error

let parses_to_immediate () =
  match Handler.resolve_directive None with
  | Ok Values.Execution_directive.Immediate -> ()
  | Ok _ -> Alcotest.fail "fallback should be Immediate"
  | Error e -> Alcotest.failf "unexpected error: %s" (Cmd_err.to_string e)

let parses_kind_immediate_explicit () =
  let d : Cmd.directive = { kind = "IMMEDIATE"; params = None } in
  match Handler.resolve_directive (Some d) with
  | Ok Values.Execution_directive.Immediate -> ()
  | Ok _ -> Alcotest.fail "expected Immediate"
  | Error e -> Alcotest.failf "unexpected error: %s" (Cmd_err.to_string e)

let parses_kind_twap_lowercase () =
  let params = {|{"n_slices": 4, "window_seconds": 60, "start_at": 1700000000}|} in
  let d : Cmd.directive = { kind = "twap"; params = Some params } in
  match Handler.resolve_directive (Some d) with
  | Ok (Values.Execution_directive.Twap p) ->
      Alcotest.(check int) "n_slices" 4 p.n_slices;
      Alcotest.(check int) "window_seconds" 60 p.window_seconds
  | Ok _ -> Alcotest.fail "expected Twap"
  | Error e -> Alcotest.failf "unexpected error: %s" (Cmd_err.to_string e)

let parses_kind_vwap () =
  let params =
    {|{"n_slices": 4, "window_seconds": 60, "start_at": 1700000000, "volume_profile": [0.1, 0.3, 0.4, 0.2]}|}
  in
  let d : Cmd.directive = { kind = "VWAP"; params = Some params } in
  match Handler.resolve_directive (Some d) with
  | Ok (Values.Execution_directive.Vwap p) -> Alcotest.(check int) "n_slices" 4 p.n_slices
  | Ok _ -> Alcotest.fail "expected Vwap"
  | Error e -> Alcotest.failf "unexpected error: %s" (Cmd_err.to_string e)

let parses_kind_pov () =
  let d : Cmd.directive =
    { kind = "POV"; params = Some {|{"participation_rate": 0.2, "timeframe": "1m"}|} }
  in
  match Handler.resolve_directive (Some d) with
  | Ok (Values.Execution_directive.Pov p) ->
      Alcotest.(check (float 0.0001)) "rate" 0.2 p.participation_rate;
      Alcotest.(check string) "timeframe" "1m" p.timeframe
  | Ok _ -> Alcotest.fail "expected Pov"
  | Error e -> Alcotest.failf "unexpected error: %s" (Cmd_err.to_string e)

let rejects_pov_missing_timeframe () =
  let d : Cmd.directive =
    { kind = "POV"; params = Some {|{"participation_rate": 0.2}|} }
  in
  match Handler.resolve_directive (Some d) with
  | Ok _ -> Alcotest.fail "expected Invalid_payload"
  | Error (Cmd_err.Invalid_payload _) -> ()
  | Error e -> Alcotest.failf "wrong error: %s" (Cmd_err.to_string e)

let parses_kind_iceberg () =
  let d : Cmd.directive = { kind = "ICEBERG"; params = Some {|{"visible_qty": "10"}|} } in
  match Handler.resolve_directive (Some d) with
  | Ok (Values.Execution_directive.Iceberg p) ->
      Alcotest.(check string) "visible_qty" "10" (Decimal.to_string p.visible_qty)
  | Ok _ -> Alcotest.fail "expected Iceberg"
  | Error e -> Alcotest.failf "unexpected error: %s" (Cmd_err.to_string e)

let parses_kind_implementation_shortfall () =
  let params =
    {|{"n_slices": 8, "window_seconds": 60, "start_at": 1700000000, "volatility": 0.2, "risk_aversion": 1.0, "temp_impact_eta": 0.05}|}
  in
  let d : Cmd.directive = { kind = "IMPLEMENTATION_SHORTFALL"; params = Some params } in
  match Handler.resolve_directive (Some d) with
  | Ok (Values.Execution_directive.Implementation_shortfall _) -> ()
  | Ok _ -> Alcotest.fail "expected Implementation_shortfall"
  | Error e -> Alcotest.failf "unexpected error: %s" (Cmd_err.to_string e)

let rejects_unknown_kind () =
  let d : Cmd.directive = { kind = "QUANTUM"; params = None } in
  match Handler.resolve_directive (Some d) with
  | Ok _ -> Alcotest.fail "expected Invalid_payload"
  | Error (Cmd_err.Invalid_payload _) -> ()
  | Error e -> Alcotest.failf "wrong error: %s" (Cmd_err.to_string e)

let rejects_twap_missing_params () =
  let d : Cmd.directive = { kind = "TWAP"; params = None } in
  match Handler.resolve_directive (Some d) with
  | Ok _ -> Alcotest.fail "expected Invalid_payload"
  | Error (Cmd_err.Invalid_payload _) -> ()
  | Error e -> Alcotest.failf "wrong error: %s" (Cmd_err.to_string e)

let rejects_twap_malformed_json () =
  let d : Cmd.directive = { kind = "TWAP"; params = Some "{not-json}" } in
  match Handler.resolve_directive (Some d) with
  | Ok _ -> Alcotest.fail "expected Invalid_payload"
  | Error (Cmd_err.Invalid_payload _) -> ()
  | Error e -> Alcotest.failf "wrong error: %s" (Cmd_err.to_string e)

let rejects_pov_out_of_range () =
  let d : Cmd.directive =
    { kind = "POV"; params = Some {|{"participation_rate": 5.0, "timeframe": "1m"}|} }
  in
  match Handler.resolve_directive (Some d) with
  | Ok _ -> Alcotest.fail "expected Invalid_payload"
  | Error (Cmd_err.Invalid_payload _) -> ()
  | Error e -> Alcotest.failf "wrong error: %s" (Cmd_err.to_string e)

let tests =
  [
    Alcotest.test_case "absent directive falls back to Immediate" `Quick
      parses_to_immediate;
    Alcotest.test_case "explicit IMMEDIATE kind parses to Immediate" `Quick
      parses_kind_immediate_explicit;
    Alcotest.test_case "TWAP kind (lowercase) parses with params" `Quick
      parses_kind_twap_lowercase;
    Alcotest.test_case "VWAP kind parses with volume profile" `Quick parses_kind_vwap;
    Alcotest.test_case "POV kind parses with rate" `Quick parses_kind_pov;
    Alcotest.test_case "ICEBERG kind parses with visible_qty" `Quick parses_kind_iceberg;
    Alcotest.test_case "IMPLEMENTATION_SHORTFALL kind parses with all params" `Quick
      parses_kind_implementation_shortfall;
    Alcotest.test_case "unknown kind is rejected" `Quick rejects_unknown_kind;
    Alcotest.test_case "TWAP with no params is rejected" `Quick
      rejects_twap_missing_params;
    Alcotest.test_case "TWAP with malformed JSON is rejected" `Quick
      rejects_twap_malformed_json;
    Alcotest.test_case "POV rate > 1.0 is rejected" `Quick rejects_pov_out_of_range;
    Alcotest.test_case "POV without timeframe is rejected" `Quick
      rejects_pov_missing_timeframe;
  ]
