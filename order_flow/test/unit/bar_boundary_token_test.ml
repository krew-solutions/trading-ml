(** Unit tests for the Bar_boundary wire-token codec — the single spelling
    shared by the footprint integration event and the watch_footprints
    command, so demand and published fact name a boundary identically. *)

open Core
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary

let has_vol_prefix tok = String.length tok > 4 && String.sub tok 0 4 = "VOL:"

let raises name tok =
  match Bar_boundary.of_token tok with
  | _ -> Alcotest.failf "%s: expected Invalid_argument for %S" name tok
  | exception Invalid_argument _ -> ()

let tests =
  [
    ( "time boundary tokens are the timeframe code",
      `Quick,
      fun () ->
        Alcotest.(check string)
          "M5" "M5"
          (Bar_boundary.to_token (Bar_boundary.Time Timeframe.M5));
        Alcotest.(check string)
          "M1" "M1"
          (Bar_boundary.to_token (Bar_boundary.Time Timeframe.M1)) );
    ( "a volume boundary token is VOL:<cap> and round-trips",
      `Quick,
      fun () ->
        let cap = Decimal.of_int 10_000 in
        let tok = Bar_boundary.to_token (Bar_boundary.Volume cap) in
        Alcotest.(check bool) "VOL: prefix" true (has_vol_prefix tok);
        (* Format-agnostic: whatever Decimal renders, of_token must invert it. *)
        Alcotest.(check string)
          "round-trips via of_token" tok
          (Bar_boundary.to_token (Bar_boundary.of_token tok)) );
    ( "of_token inverts to_token for every supported token",
      `Quick,
      fun () ->
        List.iter
          (fun tok ->
            Alcotest.(check string)
              tok tok
              (Bar_boundary.to_token (Bar_boundary.of_token tok)))
          [ "M1"; "M5"; "M15"; "M30"; "H1"; "H4"; "D1"; "VOL:1000" ] );
    ( "of_token rejects tokens that are neither a timeframe nor VOL:<decimal>",
      `Quick,
      fun () ->
        raises "garbage" "NOPE";
        raises "non-numeric cap" "VOL:abc";
        raises "empty cap" "VOL:";
        raises "empty" "" );
  ]
