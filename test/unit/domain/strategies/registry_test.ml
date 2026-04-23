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
      (* ML-driven *)
      "GBT";
    ]

let test_gbt_spec_exposes_string_param () =
  (* [Gbt_strategy] needs a [model_path] string — verify the new
     [String] variant made it through the registry's catalog shape. *)
  match Strategies.Registry.find "GBT" with
  | None -> Alcotest.fail "GBT missing from registry"
  | Some spec ->
    let has_string_param =
      List.exists (fun (_k, p) -> match p with
        | Strategies.Registry.String _ -> true
        | _ -> false) spec.params
    in
    Alcotest.(check bool) "GBT spec carries a String param"
      true has_string_param

let test_gbt_build_fails_without_model_path () =
  (* Default params have [model_path = ""]; Gbt_strategy.init
     rejects that loudly rather than trying to load a bogus file. *)
  match Strategies.Registry.find "GBT" with
  | None -> Alcotest.fail "GBT missing"
  | Some spec ->
    Alcotest.check_raises "empty model_path → Invalid_argument"
      (Invalid_argument "Gbt_strategy: model_path must be set")
      (fun () -> ignore (spec.build []))

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
  "catalog has all strategies",   `Quick, test_all_strategies_listed;
  "find known",                   `Quick, test_find_returns_some;
  "find unknown → None",          `Quick, test_find_unknown_returns_none;
  "build with empty params",      `Quick, test_build_respects_default_params;
  "GBT spec has String param",    `Quick, test_gbt_spec_exposes_string_param;
  "GBT rejects empty model_path", `Quick, test_gbt_build_fails_without_model_path;
]
