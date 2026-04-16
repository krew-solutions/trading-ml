open Ind_helpers

let uptrend () =
  let ind = Indicators.Mfi.make ~period:14 in
  let ind = feed ind (List.init 30 (fun i ->
    let p = 100.0 +. float_of_int i in
    candle ~high:(p +. 1.0) ~low:(p -. 1.0) ~volume:1000.0 p)) in
  Alcotest.(check (float 1e-6)) "mfi up = 100" 100.0 (scalar ind)

let downtrend () =
  let ind = Indicators.Mfi.make ~period:14 in
  let ind = feed ind (List.init 30 (fun i ->
    let p = 100.0 -. float_of_int i in
    candle ~high:(p +. 1.0) ~low:(p -. 1.0) ~volume:1000.0 p)) in
  Alcotest.(check (float 1e-6)) "mfi down = 0" 0.0 (scalar ind)

let tests = [
  "uptrend → 100", `Quick, uptrend;
  "downtrend → 0", `Quick, downtrend;
]
