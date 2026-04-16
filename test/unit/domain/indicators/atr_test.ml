open Ind_helpers

let constant_range () =
  (* Identical candles with H=11, L=10, C=10.5: TR = 1 every bar. *)
  let ind = Indicators.Atr.make ~period:14 in
  let ind = feed ind
    (List.init 30 (fun _ -> candle ~high:11.0 ~low:10.0 10.5)) in
  Alcotest.(check (float 1e-6)) "atr = 1" 1.0 (scalar ind)

let spike_raises_atr () =
  let calm = List.init 20 (fun _ -> candle ~high:11.0 ~low:10.0 10.5) in
  let spike = [candle ~high:20.0 ~low:10.0 15.0] in
  let ind = Indicators.Atr.make ~period:14 in
  let before = feed ind calm in
  let after  = feed before spike in
  Alcotest.(check bool) "atr grew on spike" true
    (scalar after > scalar before)

let tests = [
  "constant range", `Quick, constant_range;
  "spike raises ATR", `Quick, spike_raises_atr;
]
