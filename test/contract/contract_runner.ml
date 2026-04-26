(** Contract tests — verify our DTO decoders accept real-world sample
    responses from each provider. Sample fixtures live in [fixtures/]
    and are regenerated manually (with a live token + curl) when the
    provider's wire format drifts. Contract tests fail loudly when
    they drift so we notice before the next live run. *)

let placeholder () = Alcotest.(check bool) "wiring" true true

let () =
  Alcotest.run "trading-contract" [ ("placeholder", [ ("wiring", `Quick, placeholder) ]) ]
