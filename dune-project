(lang dune 3.10)
(name trading)
(generate_opam_files true)

; Restrict @fmt to OCaml — leave dune files alone, since their
; auto-format mangles multi-line bash blocks in our @gospel/@why3
; rules into unreadable `\n`-escaped one-liners.
(formatting (enabled_for ocaml))

(package
 (name trading)
 (synopsis "Functional algorithmic trading system with Finam Trade connector")
 (description "Strategy/indicator framework, backtester, Finam REST+WS connector, Gospel-verified core")
 (depends
  (ocaml (>= 5.1))
  (dune (>= 3.10))
  eio
  eio_main
  cohttp
  cohttp-eio
  yojson
  ppx_yojson_conv
  atd
  atdgen
  tls
  tls-eio
  uri
  base64
  digestif
  uuidm
  (alcotest :with-test)
  (qcheck :with-test)
  (gospel (>= 0.3.1))
  (why3 (>= 1.8))
  (alt-ergo (>= 2.6))
  (z3 (>= 4.13))
  (ascetic_ddd (>= 0.1))))
