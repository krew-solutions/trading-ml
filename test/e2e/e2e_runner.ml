(** End-to-end tests — start the real HTTP server in-process, drive it
    over TCP with a real HTTP client, assert on the response. Slow,
    so kept in a separate executable from [unit]. *)

(** Placeholder until the first e2e scenario lands. Having the dune
    stanza and runner in place now means adding a test is just a new
    file + one line here. *)
let placeholder () = Alcotest.(check bool) "wiring" true true

let () =
  Alcotest.run "trading-e2e" [ ("placeholder", [ ("wiring", `Quick, placeholder) ]) ]
