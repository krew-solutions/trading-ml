open Ind_helpers

let close_always_at_high () =
  let ind = Indicators.Cmf.make ~period:20 in
  let ind = feed ind (List.init 25 (fun _ ->
    candle ~high:10.0 ~low:0.0 ~volume:100.0 10.0)) in
  Alcotest.(check (float 1e-6)) "cmf +1" 1.0 (scalar ind)

let close_always_at_low () =
  let ind = Indicators.Cmf.make ~period:20 in
  let ind = feed ind (List.init 25 (fun _ ->
    candle ~high:10.0 ~low:0.0 ~volume:100.0 0.0)) in
  Alcotest.(check (float 1e-6)) "cmf -1" (-1.0) (scalar ind)

let tests = [
  "close at high → +1", `Quick, close_always_at_high;
  "close at low → -1",  `Quick, close_always_at_low;
]
