open Ind_helpers

let basic () =
  let ind = Indicators.Sma.make ~period:3 in
  let ind = feed ind (List.map candle [1.0; 2.0; 3.0]) in
  Alcotest.(check (float 1e-9)) "sma 1,2,3" 2.0 (scalar ind);
  let ind = feed ind [candle 10.0] in
  Alcotest.(check (float 1e-9)) "sma window slides" 5.0 (scalar ind)

let partial () =
  let ind = Indicators.Sma.make ~period:5 in
  let ind = feed ind (List.map candle [1.0; 2.0]) in
  Alcotest.(check bool) "not enough data" true
    (Indicators.Indicator.value ind = None)

let tests = [
  "basic", `Quick, basic;
  "partial window", `Quick, partial;
]
