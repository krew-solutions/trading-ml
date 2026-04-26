(** Unit tests for [Logistic_regression.Logistic] — sigmoid, predict,
    SGD convergence, weight export/import. *)

let test_sigmoid_bounds () =
  Alcotest.(check bool)
    "sigmoid(0) = 0.5" true
    (Float.abs (Logistic_regression.Logistic.sigmoid 0.0 -. 0.5) < 1e-9);
  Alcotest.(check bool)
    "sigmoid(large) → 1" true
    (Logistic_regression.Logistic.sigmoid 100.0 > 0.999);
  Alcotest.(check bool)
    "sigmoid(-large) → 0" true
    (Logistic_regression.Logistic.sigmoid (-100.0) < 0.001)

let test_predict_untrained_is_half () =
  let m = Logistic_regression.Logistic.make ~n_features:3 () in
  let p = Logistic_regression.Logistic.predict m [| 1.0; 2.0; 3.0 |] in
  Alcotest.(check bool) "untrained model predicts ~0.5" true (Float.abs (p -. 0.5) < 1e-9)

let test_sgd_converges () =
  let m = Logistic_regression.Logistic.make ~n_features:1 ~lr:0.5 () in
  let data =
    [
      ([| 2.0 |], 1.0);
      ([| 3.0 |], 1.0);
      ([| 1.0 |], 1.0);
      ([| -2.0 |], 0.0);
      ([| -3.0 |], 0.0);
      ([| -1.0 |], 0.0);
    ]
  in
  let _loss = Logistic_regression.Logistic.train m ~epochs:100 data in
  let p_pos = Logistic_regression.Logistic.predict m [| 5.0 |] in
  let p_neg = Logistic_regression.Logistic.predict m [| -5.0 |] in
  Alcotest.(check bool) "positive input → high P" true (p_pos > 0.8);
  Alcotest.(check bool) "negative input → low P" true (p_neg < 0.2)

let test_export_import () =
  let m = Logistic_regression.Logistic.make ~n_features:2 () in
  let data = [ ([| 1.0; 0.0 |], 1.0); ([| 0.0; 1.0 |], 0.0) ] in
  let _ = Logistic_regression.Logistic.train m ~epochs:50 data in
  let w = Logistic_regression.Logistic.export_weights m in
  let m2 = Logistic_regression.Logistic.of_weights w in
  let p1 = Logistic_regression.Logistic.predict m [| 1.0; 0.0 |] in
  let p2 = Logistic_regression.Logistic.predict m2 [| 1.0; 0.0 |] in
  Alcotest.(check (float 1e-9)) "exported model predicts same" p1 p2

let test_json_round_trip () =
  (* Train a model, serialise to JSON, parse back — the recovered
     model must give identical predictions to the original. *)
  let m = Logistic_regression.Logistic.make ~n_features:3 ~lr:0.02 ~l2:1e-3 () in
  let data =
    [
      ([| 1.0; 0.5; -0.2 |], 1.0); ([| -0.3; 0.1; 0.8 |], 0.0); ([| 0.5; -0.7; 0.1 |], 1.0);
    ]
  in
  let _ = Logistic_regression.Logistic.train m ~epochs:30 data in
  let j = Logistic_regression.Logistic.to_json m in
  let m' = Logistic_regression.Logistic.of_json j in
  let probe = [| 0.2; -0.3; 0.5 |] in
  Alcotest.(check (float 1e-12))
    "round-trip predicts identically"
    (Logistic_regression.Logistic.predict m probe)
    (Logistic_regression.Logistic.predict m' probe)

let test_json_missing_hyperparams_use_defaults () =
  (* [of_json] must tolerate a weights-only payload (older
     serialisations, hand-written fixtures) and fall back to
     [make]'s default [lr] / [l2]. *)
  let j = Yojson.Safe.from_string {| { "weights": [0.1, 0.2, 0.3] } |} in
  let m = Logistic_regression.Logistic.of_json j in
  Alcotest.(check int)
    "3 weights" 3
    (Array.length (Logistic_regression.Logistic.export_weights m))

let test_json_rejects_malformed () =
  let bad = Yojson.Safe.from_string {| { "weights": "not an array" } |} in
  Alcotest.check_raises "non-array weights → Invalid_argument"
    (Invalid_argument "Logistic.of_json: missing or non-array [weights]") (fun () ->
      ignore (Logistic_regression.Logistic.of_json bad))

let test_file_round_trip () =
  let path =
    Filename.concat
      (try Sys.getenv "TMPDIR" with Not_found -> "/tmp")
      (Printf.sprintf "logistic_test_%d_%d.json" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1e6)))
  in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      let m = Logistic_regression.Logistic.make ~n_features:2 ~lr:0.05 () in
      let _ =
        Logistic_regression.Logistic.train m ~epochs:10
          [ ([| 1.0; 0.0 |], 1.0); ([| 0.0; 1.0 |], 0.0) ]
      in
      Logistic_regression.Logistic.to_file ~path m;
      Alcotest.(check bool) "file created" true (Sys.file_exists path);
      let m' = Logistic_regression.Logistic.of_file path in
      let probe = [| 0.3; 0.7 |] in
      Alcotest.(check (float 1e-12))
        "file round-trip identical"
        (Logistic_regression.Logistic.predict m probe)
        (Logistic_regression.Logistic.predict m' probe))

let tests =
  [
    ("sigmoid bounds", `Quick, test_sigmoid_bounds);
    ("untrained predicts 0.5", `Quick, test_predict_untrained_is_half);
    ("SGD converges", `Quick, test_sgd_converges);
    ("export/import weights", `Quick, test_export_import);
    ("json round-trip", `Quick, test_json_round_trip);
    ("json missing hyperparams → defs", `Quick, test_json_missing_hyperparams_use_defaults);
    ("json rejects malformed", `Quick, test_json_rejects_malformed);
    ("file round-trip", `Quick, test_file_round_trip);
  ]
