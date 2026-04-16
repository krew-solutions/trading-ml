open Ind_helpers

let constant () =
  let ind = Indicators.Wma.make ~period:5 in
  let ind = feed ind (List.init 10 (fun _ -> candle 10.0)) in
  Alcotest.(check (float 1e-9)) "wma const" 10.0 (scalar ind)

let weights () =
  (* WMA(3) of [1, 2, 6]: (1·1 + 2·2 + 3·6) / 6 = 23/6 *)
  let ind = Indicators.Wma.make ~period:3 in
  let ind = feed ind (List.map candle [1.0; 2.0; 6.0]) in
  Alcotest.(check (float 1e-9)) "weighted" (23.0 /. 6.0) (scalar ind)

let tests = [
  "constant", `Quick, constant;
  "linear weights", `Quick, weights;
]
