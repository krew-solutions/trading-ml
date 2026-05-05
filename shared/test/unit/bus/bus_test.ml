(** Tests for the [Bus] dispatcher itself — scheme registry,
    error paths. The actual messaging behaviour lives in the
    adapter and is exercised by [In_memory_test]. *)

let test_unknown_scheme_raises () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let bus = Bus.create () in
  let broker = In_memory.create ~sw in
  Bus.register bus ~scheme:"in-memory" (In_memory.adapter broker);
  Alcotest.check_raises "no adapter for kafka:// → Unknown_scheme"
    (Bus.Unknown_scheme "kafka") (fun () ->
      let _ = Bus.consumer bus ~uri:"kafka://x" ~group:"g" ~deserialize:Fun.id in
      ())

let test_already_registered_raises () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let bus = Bus.create () in
  let b1 = In_memory.create ~sw in
  let b2 = In_memory.create ~sw in
  Bus.register bus ~scheme:"in-memory" (In_memory.adapter b1);
  Alcotest.check_raises "second register on same scheme → Already_registered"
    (Bus.Already_registered "in-memory") (fun () ->
      Bus.register bus ~scheme:"in-memory" (In_memory.adapter b2))

let test_uri_without_scheme_raises () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let bus = Bus.create () in
  Bus.register bus ~scheme:"in-memory" (In_memory.adapter (In_memory.create ~sw));
  Alcotest.check_raises "URI without scheme → Unknown_scheme"
    (Bus.Unknown_scheme "no-scheme-here") (fun () ->
      let _ = Bus.consumer bus ~uri:"no-scheme-here" ~group:"g" ~deserialize:Fun.id in
      ())

let test_per_bus_isolation_of_registry () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let b1 = Bus.create () in
  let b2 = Bus.create () in
  Bus.register b1 ~scheme:"in-memory" (In_memory.adapter (In_memory.create ~sw));
  (* b2 has no adapter — proves the registry is per-bus, not global *)
  Alcotest.check_raises "b2 has no in-memory adapter → Unknown_scheme"
    (Bus.Unknown_scheme "in-memory") (fun () ->
      let _ = Bus.consumer b2 ~uri:"in-memory://x" ~group:"g" ~deserialize:Fun.id in
      ())

let tests =
  [
    ("unknown scheme raises", `Quick, test_unknown_scheme_raises);
    ("already registered raises", `Quick, test_already_registered_raises);
    ("uri without scheme raises", `Quick, test_uri_without_scheme_raises);
    ("per-bus isolation of registry", `Quick, test_per_bus_isolation_of_registry);
  ]
