open Ind_helpers

let flat_ad_is_zero () =
  (* Bars at midrange → mfm = 0 → A/D stays at 0 → oscillator = 0. *)
  let ind = Indicators.Chaikin_oscillator.make ~fast:3 ~slow:10 () in
  let ind = feed ind (List.init 30 (fun _ ->
    candle ~high:10.0 ~low:0.0 ~volume:100.0 5.0)) in
  Alcotest.(check (float 1e-6)) "chaikin flat" 0.0 (scalar ind)

let produces_value_when_ad_trends () =
  let ind = Indicators.Chaikin_oscillator.make ~fast:3 ~slow:10 () in
  let ind = feed ind (List.init 40 (fun i ->
    let c = float_of_int (i mod 5) in
    candle ~high:10.0 ~low:0.0 ~volume:100.0 c)) in
  Alcotest.(check bool) "defined" true
    (not (Float.is_nan (scalar ind)))

let tests = [
  "flat A/D → zero", `Quick, flat_ad_is_zero;
  "defined on trends", `Quick, produces_value_when_ad_trends;
]
