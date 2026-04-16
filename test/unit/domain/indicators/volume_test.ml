open Ind_helpers

let lifts_volume () =
  let ind = Indicators.Volume.make () in
  let ind = feed ind [candle ~volume:123.0 10.0] in
  Alcotest.(check (float 1e-9)) "volume" 123.0 (scalar ind)

let tracks_latest_bar () =
  let ind = Indicators.Volume.make () in
  let ind = feed ind [
    candle ~volume:100.0 10.0;
    candle ~volume:250.0 11.0;
    candle ~volume:42.0  12.0;
  ] in
  Alcotest.(check (float 1e-9)) "latest" 42.0 (scalar ind)

let tests = [
  "lifts volume",       `Quick, lifts_volume;
  "tracks latest bar",  `Quick, tracks_latest_bar;
]
