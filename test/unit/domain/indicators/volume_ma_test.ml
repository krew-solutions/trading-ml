open Ind_helpers

let constant_volume () =
  let ind = Indicators.Volume_ma.make ~period:5 in
  let ind = feed ind (List.init 10 (fun _ -> candle ~volume:500.0 10.0)) in
  Alcotest.(check (float 1e-9)) "vma = 500" 500.0 (scalar ind)

let window_slides () =
  let ind = Indicators.Volume_ma.make ~period:3 in
  let ind = feed ind [
    candle ~volume:10.0 1.0;
    candle ~volume:20.0 1.0;
    candle ~volume:30.0 1.0;  (* (10+20+30)/3 = 20 *)
  ] in
  Alcotest.(check (float 1e-9)) "vma 10,20,30" 20.0 (scalar ind);
  let ind = feed ind [candle ~volume:60.0 1.0] in
  (* (20+30+60)/3 = 36.67 *)
  Alcotest.(check (float 1e-6)) "vma after slide" (110.0 /. 3.0) (scalar ind)

let partial_window () =
  let ind = Indicators.Volume_ma.make ~period:5 in
  let ind = feed ind [candle ~volume:100.0 1.0; candle ~volume:200.0 1.0] in
  Alcotest.(check bool) "not enough data" true
    (Indicators.Indicator.value ind = None)

let tests = [
  "constant volume",  `Quick, constant_volume;
  "window slides",    `Quick, window_slides;
  "partial window",   `Quick, partial_window;
]
