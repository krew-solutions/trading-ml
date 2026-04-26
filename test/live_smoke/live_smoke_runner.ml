(** Live smoke tests — hit the real broker API with credentials
    from env (FINAM_SECRET, BCS_SECRET). Disabled by default; opt
    in with `dune build @live_smoke`. Flaky by design: network,
    geo-blocks, broker downtime all cause failures we don't want
    CI to mistake for regressions.

    Each suite is individually gated on its broker's credentials
    being present — missing env skips cleanly rather than failing. *)

let () =
  Alcotest.run "trading-live-smoke"
    [ ("finam", Finam_smoke.tests); ("bcs", Bcs_smoke.tests) ]
