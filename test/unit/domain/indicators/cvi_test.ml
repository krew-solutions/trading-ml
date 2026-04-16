open Ind_helpers

let flat_range () =
  let ind = Indicators.Cvi.make ~period:10 in
  let ind = feed ind
    (List.init 30 (fun _ -> candle ~high:11.0 ~low:10.0 10.5)) in
  Alcotest.(check (float 1e-6)) "cvi flat" 0.0 (scalar ind)

let widening_range () =
  let ind = Indicators.Cvi.make ~period:10 in
  let ind = feed ind (List.init 40 (fun i ->
    let h = 10.0 +. float_of_int i *. 0.5 in
    candle ~high:h ~low:0.0 (h /. 2.0))) in
  Alcotest.(check bool) "cvi > 0" true (scalar ind > 0.0)

let narrowing_range () =
  let ind = Indicators.Cvi.make ~period:10 in
  let ind = feed ind (List.init 40 (fun i ->
    let h = 30.0 -. float_of_int i *. 0.5 in
    candle ~high:h ~low:0.0 (h /. 2.0))) in
  Alcotest.(check bool) "cvi < 0" true (scalar ind < 0.0)

let tests = [
  "flat range → 0", `Quick, flat_range;
  "widening → +",   `Quick, widening_range;
  "narrowing → -",  `Quick, narrowing_range;
]
