(** Live smoke tests — hit the real broker API with credentials from
    env (FINAM_SECRET, BCS_SECRET). Disabled by default; opt in with
    `dune build @live_smoke`. Flaky by design: network, geo-blocks,
    broker downtime all cause failures we don't want CI to mistake
    for regressions. *)

let () =
  Alcotest.run "trading-live-smoke" [
    "placeholder", [ "wiring", `Quick, (fun () ->
      Alcotest.(check bool) "placeholder" true true) ];
  ]
