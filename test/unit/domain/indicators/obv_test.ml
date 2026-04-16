open Ind_helpers

let up_down_mix () =
  let ind = Indicators.Obv.make () in
  let cs = [
    candle ~volume:10.0 100.0;  (* seed, OBV = 0 *)
    candle ~volume:20.0 101.0;  (* up → +20 *)
    candle ~volume:5.0  100.0;  (* down → -5 *)
    candle ~volume:8.0  101.0;  (* up → +8 *)
  ] in
  Alcotest.(check (float 1e-9)) "obv = 23" 23.0 (scalar (feed ind cs))

let flat_closes () =
  let ind = Indicators.Obv.make () in
  let cs = List.init 10 (fun _ -> candle ~volume:100.0 50.0) in
  Alcotest.(check (float 1e-9)) "obv = 0" 0.0 (scalar (feed ind cs))

let tests = [
  "up/down volume", `Quick, up_down_mix;
  "flat closes → 0", `Quick, flat_closes;
]
