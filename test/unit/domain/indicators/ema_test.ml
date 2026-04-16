open Ind_helpers

let converges () =
  let ind = Indicators.Ema.make ~period:5 in
  let ind = feed ind (List.init 50 (fun _ -> candle 10.0)) in
  Alcotest.(check (float 1e-6)) "ema const" 10.0 (scalar ind)

let seed_equals_sma () =
  (* First emitted value equals the SMA of the first [period] samples. *)
  let ind = Indicators.Ema.make ~period:5 in
  let ind = feed ind (List.map candle [10.0; 20.0; 30.0; 40.0; 50.0]) in
  Alcotest.(check (float 1e-9)) "seed = mean" 30.0 (scalar ind)

let tests = [
  "converges on constant", `Quick, converges;
  "seed = SMA", `Quick, seed_equals_sma;
]
