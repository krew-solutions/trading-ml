(** Server-side WebSocket helper used only by the integration tests.
    Completes the handshake, then echoes every text frame back. Kept
    out of the production paths — this library is a client-only
    connector. Living under [lib/finam] so the test binary can
    reach it without extra dune plumbing. *)

let header_line k v = k ^ ": " ^ v ^ "\r\n"

let read_request_headers (buf : Eio.Buf_read.t) : (string * string) list =
  let _ = Eio.Buf_read.line buf in   (* request line, ignored *)
  let rec loop acc =
    match Eio.Buf_read.line buf with
    | "" -> List.rev acc
    | line ->
      match String.index_opt line ':' with
      | None -> loop acc
      | Some i ->
        let k = String.sub line 0 i |> String.trim |> String.lowercase_ascii in
        let v = String.sub line (i + 1) (String.length line - i - 1)
                |> String.trim in
        loop ((k, v) :: acc)
  in
  loop []

(** Accept one client, complete the handshake, echo text frames until
    the client sends a close. Returns when the connection ends. *)
let accept_and_echo flow : unit =
  let buf = Eio.Buf_read.of_flow flow ~max_size:65536 in
  let hdrs = read_request_headers buf in
  let key = List.assoc "sec-websocket-key" hdrs in
  let accept = Finam.Ws_frame.accept_token key in
  let resp =
    "HTTP/1.1 101 Switching Protocols\r\n" ^
    header_line "Upgrade" "websocket" ^
    header_line "Connection" "Upgrade" ^
    header_line "Sec-WebSocket-Accept" accept ^
    "\r\n"
  in
  Eio.Flow.copy_string resp flow;
  let reader =
    let module R = struct
      let read_exact n =
        try Eio.Buf_read.take n buf
        with End_of_file -> failwith "srv: short read"
    end in
    (module R : Finam.Ws_frame.Reader)
  in
  let rec loop () =
    match Finam.Ws_frame.decode reader with
    | { opcode = Close; _ } ->
      (* Echo the close back. Server→client frames are unmasked. *)
      let f = { Finam.Ws_frame.fin = true; opcode = Close; payload = "" } in
      Eio.Flow.copy_string (Finam.Ws_frame.encode ~mask_key:"" f) flow
    | { opcode = Text; payload; _ } ->
      let out = { Finam.Ws_frame.fin = true; opcode = Text; payload } in
      Eio.Flow.copy_string (Finam.Ws_frame.encode ~mask_key:"" out) flow;
      loop ()
    | { opcode = Ping; payload; _ } ->
      let out = { Finam.Ws_frame.fin = true; opcode = Pong; payload } in
      Eio.Flow.copy_string (Finam.Ws_frame.encode ~mask_key:"" out) flow;
      loop ()
    | _ -> loop ()
  in
  try loop () with _ -> ()
