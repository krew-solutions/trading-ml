(** Pure byte-level tests for [Finam.Ws_frame]. Build a [Reader] from a
    byte cursor so we can run the decoder without any network. *)

open Finam

module Byte_reader (B : sig val bytes : string ref end) = struct
  let read_exact n =
    let s = !B.bytes in
    if String.length s < n then failwith "short read";
    let out = String.sub s 0 n in
    B.bytes := String.sub s n (String.length s - n);
    out
end

let reader_of bytes =
  let module R = Byte_reader (struct let bytes = ref bytes end) in
  (module R : Ws_frame.Reader)

let test_roundtrip_text_small () =
  let f = { Ws_frame.fin = true; opcode = Text; payload = "hello" } in
  let encoded = Ws_frame.encode ~mask_key:"" f in
  let decoded = Ws_frame.decode (reader_of encoded) in
  Alcotest.(check bool) "fin" true decoded.fin;
  Alcotest.(check string) "payload" "hello" decoded.payload

let test_roundtrip_masked () =
  let f = { Ws_frame.fin = true; opcode = Text; payload = "masked!" } in
  let key = "\x01\x02\x03\x04" in
  let encoded = Ws_frame.encode ~mask_key:key f in
  let decoded = Ws_frame.decode (reader_of encoded) in
  Alcotest.(check string) "payload survives mask roundtrip"
    "masked!" decoded.payload

let test_extended_len_16 () =
  let payload = String.make 200 'A' in
  let f = { Ws_frame.fin = true; opcode = Text; payload } in
  let encoded = Ws_frame.encode ~mask_key:"" f in
  (* Byte 1 should be 126 (indicates 16-bit length follows). *)
  Alcotest.(check int) "extended-16 marker" 126
    (Char.code encoded.[1]);
  let decoded = Ws_frame.decode (reader_of encoded) in
  Alcotest.(check int) "len" 200 (String.length decoded.payload)

let test_extended_len_64 () =
  let payload = String.make 70_000 'B' in
  let f = { Ws_frame.fin = true; opcode = Binary; payload } in
  let encoded = Ws_frame.encode ~mask_key:"" f in
  Alcotest.(check int) "extended-64 marker" 127
    (Char.code encoded.[1]);
  let decoded = Ws_frame.decode (reader_of encoded) in
  Alcotest.(check int) "len" 70_000 (String.length decoded.payload)

let test_ping_pong_opcodes () =
  let ping = { Ws_frame.fin = true; opcode = Ping; payload = "pong me" } in
  let encoded = Ws_frame.encode ~mask_key:"" ping in
  let decoded = Ws_frame.decode (reader_of encoded) in
  Alcotest.(check bool) "is ping" true
    (decoded.opcode = Ws_frame.Ping);
  Alcotest.(check string) "payload" "pong me" decoded.payload

let test_mask_involution () =
  (* Masking is its own inverse with the same key. *)
  let key = "\xaa\x55\xf0\x0f" in
  let s = "a very ordinary payload" in
  let once = Ws_frame.mask_payload ~key s in
  let twice = Ws_frame.mask_payload ~key once in
  Alcotest.(check string) "mask · mask = id" s twice

let test_accept_token () =
  (* Known vector from RFC 6455 §1.3: key "dGhlIHNhbXBsZSBub25jZQ==" →
     accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=". *)
  let accept = Ws_frame.accept_token "dGhlIHNhbXBsZSBub25jZQ==" in
  Alcotest.(check string) "RFC 6455 example"
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" accept

let tests = [
  "roundtrip text (short)", `Quick, test_roundtrip_text_small;
  "roundtrip masked",       `Quick, test_roundtrip_masked;
  "extended 16-bit length", `Quick, test_extended_len_16;
  "extended 64-bit length", `Quick, test_extended_len_64;
  "ping opcode preserved",  `Quick, test_ping_pong_opcodes;
  "masking is involution",  `Quick, test_mask_involution;
  "Sec-WebSocket-Accept",   `Quick, test_accept_token;
]
