open Ind_helpers

let constants_collapse () =
  let ind = Indicators.Bollinger.make ~period:20 ~k:2.0 () in
  let ind = feed ind (List.init 25 (fun _ -> candle 50.0)) in
  match values ind with
  | [l; m; u] ->
    Alcotest.(check (float 1e-6)) "lower = middle" m l;
    Alcotest.(check (float 1e-6)) "upper = middle" m u;
    Alcotest.(check (float 1e-6)) "middle = 50" 50.0 m
  | _ -> Alcotest.fail "no output"

let symmetric_spread () =
  (* upper - middle = middle - lower = k·σ on any non-constant window. *)
  let ind = Indicators.Bollinger.make ~period:10 ~k:2.0 () in
  let ind = feed ind (List.init 12 (fun i ->
    candle (float_of_int (i + 1)))) in
  match values ind with
  | [l; m; u] ->
    Alcotest.(check (float 1e-9)) "symmetric"
      (u -. m) (m -. l);
    Alcotest.(check bool) "band > 0" true (u -. m > 0.0)
  | _ -> Alcotest.fail "no output"

let tests = [
  "constants collapse", `Quick, constants_collapse;
  "symmetric bands", `Quick, symmetric_spread;
]
