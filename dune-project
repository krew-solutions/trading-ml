(lang dune 3.10)
(name trading)
(generate_opam_files true)

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
  tls
  tls-eio
  uri
  base64
  digestif
  (alcotest :with-test)
  (qcheck :with-test)
  (gospel (>= 0.3.1))))
