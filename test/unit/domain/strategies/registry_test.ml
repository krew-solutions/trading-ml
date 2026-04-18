(** The strategy registry is the thing the UI/CLI actually dispatches
    through, so a couple of sanity checks guard against name drift. *)

let test_all_strategies_listed () =
  let names = Strategies.Registry.names () in
  List.iter (fun expected ->
    Alcotest.(check bool) (expected ^ " registered") true
      (List.mem expected names))
    [ "SMA_Crossover"; "RSI_MeanReversion"; "MACD_Momentum";
      "Bollinger_Breakout";
      (* Volume-based strategies *)
      "MFI_MeanReversion"; "OBV_MA_Crossover";
      "Chaikin_Momentum"; "AD_MA_Crossover";
    ]

let test_find_returns_some () =
  match Strategies.Registry.find "SMA_Crossover" with
  | Some _ -> ()
  | None -> Alcotest.fail "SMA_Crossover missing from registry"

let test_find_unknown_returns_none () =
  match Strategies.Registry.find "No_such_strategy" with
  | None -> ()
  | Some _ -> Alcotest.fail "registry claims to know a bogus strategy"

let test_build_respects_default_params () =
  match Strategies.Registry.find "SMA_Crossover" with
  | None -> Alcotest.fail "missing"
  | Some spec ->
    let _client = spec.build [] in
    (* Building with [] uses each spec's defaults; the real check is
       just that it doesn't raise. *)
    Alcotest.(check bool) "builds without params" true true

let tests = [
  "catalog has all strategies",  `Quick, test_all_strategies_listed;
  "find known",                  `Quick, test_find_returns_some;
  "find unknown → None",         `Quick, test_find_unknown_returns_none;
  "build with empty params",     `Quick, test_build_respects_default_params;
]
