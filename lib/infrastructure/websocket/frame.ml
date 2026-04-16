(** Minimal RFC 6455 frame codec — pure byte-level functions.
    Scope: text/binary data frames plus control frames (close/ping/pong),
    single-fragment messages (FIN=1), no compression. Enough for the
    Finam async-api which always emits one JSON doc per frame. *)

type opcode =
  | Continuation  (* 0x0 *)
  | Text          (* 0x1 *)
  | Binary        (* 0x2 *)
  | Close         (* 0x8 *)
  | Ping          (* 0x9 *)
  | Pong          (* 0xA *)
  | Unknown of int

let opcode_of_int = function
  | 0x0 -> Continuation
  | 0x1 -> Text
  | 0x2 -> Binary
  | 0x8 -> Close
  | 0x9 -> Ping
  | 0xA -> Pong
  | n   -> Unknown n

let opcode_to_int = function
  | Continuation -> 0x0
  | Text -> 0x1 | Binary -> 0x2
  | Close -> 0x8 | Ping -> 0x9 | Pong -> 0xA
  | Unknown n -> n land 0xF

type frame = {
  fin : bool;
  opcode : opcode;
  payload : string;
}

let mask_payload ~key (s : string) : string =
  if String.length key <> 4 then
    invalid_arg "ws_frame.mask_payload: key must be 4 bytes";
  let n = String.length s in
  let out = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set out i
      (Char.chr (Char.code s.[i] lxor Char.code key.[i land 3]))
  done;
  Bytes.unsafe_to_string out

(** Encode a client→server frame. Client frames MUST carry a masking
    key — [mask_key] is expected to be freshly-random bytes (RFC 6455
    §5.3). Passing the empty string disables masking (server→client
    path, used in tests). *)
let encode ~mask_key (f : frame) : string =
  let buf = Buffer.create (String.length f.payload + 14) in
  let b0 = (if f.fin then 0x80 else 0) lor (opcode_to_int f.opcode) in
  Buffer.add_char buf (Char.chr b0);
  let len = String.length f.payload in
  let mask_bit = if String.length mask_key = 4 then 0x80 else 0 in
  if len <= 125 then
    Buffer.add_char buf (Char.chr (mask_bit lor len))
  else if len <= 0xFFFF then begin
    Buffer.add_char buf (Char.chr (mask_bit lor 126));
    Buffer.add_char buf (Char.chr ((len lsr 8) land 0xFF));
    Buffer.add_char buf (Char.chr (len land 0xFF))
  end else begin
    Buffer.add_char buf (Char.chr (mask_bit lor 127));
    for i = 7 downto 0 do
      Buffer.add_char buf (Char.chr ((len lsr (i * 8)) land 0xFF))
    done
  end;
  if mask_bit <> 0 then begin
    Buffer.add_string buf mask_key;
    Buffer.add_string buf (mask_payload ~key:mask_key f.payload)
  end else
    Buffer.add_string buf f.payload;
  Buffer.contents buf

(** Reader protocol the client-side driver talks to: pulls N bytes,
    blocking until available. Concrete implementations wrap
    [Eio.Buf_read.t] in real code, or a byte cursor in tests. *)
module type Reader = sig
  val read_exact : int -> string
end

let decode (module R : Reader) : frame =
  let b0 = Char.code (R.read_exact 1).[0] in
  let fin = (b0 land 0x80) <> 0 in
  let opcode = opcode_of_int (b0 land 0x0F) in
  let b1 = Char.code (R.read_exact 1).[0] in
  let masked = (b1 land 0x80) <> 0 in
  let len7 = b1 land 0x7F in
  let length =
    if len7 < 126 then len7
    else if len7 = 126 then
      let b = R.read_exact 2 in
      (Char.code b.[0] lsl 8) lor Char.code b.[1]
    else
      let b = R.read_exact 8 in
      let n = ref 0 in
      for i = 0 to 7 do
        n := (!n lsl 8) lor Char.code b.[i]
      done;
      !n
  in
  let mask_key = if masked then R.read_exact 4 else "" in
  let payload = R.read_exact length in
  let payload =
    if masked then mask_payload ~key:mask_key payload else payload
  in
  { fin; opcode; payload }

(** 16 random bytes → base64 (for Sec-WebSocket-Key). Uses the OCaml
    [Random] stdlib — sufficient for key generation since the server
    only uses it to derive Sec-WebSocket-Accept. *)
let random_key () : string =
  let b = Bytes.create 16 in
  for i = 0 to 15 do
    Bytes.set b i (Char.chr (Random.int 256))
  done;
  Base64.encode_string (Bytes.to_string b)

(** 4-byte masking key for a single outgoing frame. *)
let random_mask () : string =
  let b = Bytes.create 4 in
  for i = 0 to 3 do
    Bytes.set b i (Char.chr (Random.int 256))
  done;
  Bytes.to_string b

(** RFC 6455 §4.1: Sec-WebSocket-Accept = base64(sha1(key ++ magic)). *)
let accept_token (key : string) : string =
  let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" in
  let digest = Digestif.SHA1.(digest_string (key ^ magic) |> to_raw_string) in
  Base64.encode_string digest
