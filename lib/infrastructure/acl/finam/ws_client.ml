(** Minimal WebSocket client over Eio + TLS.
    Handles the HTTP/1.1 Upgrade handshake, then exposes message-level
    [send_text] / [recv] that transparently manage masking, ping/pong
    control frames and close handshakes. Single-fragment text messages
    only — Finam's async-api never fragments. *)

type t = {
  flow : Eio.Flow.two_way_ty Eio.Resource.t;
  buf  : Eio.Buf_read.t;
  mutex : Eio.Mutex.t;             (* serialises writes to [flow] *)
  mutable closed : bool;
}

type message =
  | Text of string
  | Binary of string
  | Close of { code : int option; reason : string }

let eof_buf_read (buf : Eio.Buf_read.t) (n : int) : string =
  try Eio.Buf_read.take n buf
  with End_of_file -> failwith "ws: connection closed while reading frame"

(** A [Ws_frame.Reader] view onto [Eio.Buf_read.t]. *)
let reader_of buf : (module Ws_frame.Reader) =
  let module R = struct
    let read_exact n = eof_buf_read buf n
  end in
  (module R)

let write_raw (t : t) (s : string) : unit =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    Eio.Flow.copy_string s t.flow)

let send_frame (t : t) (f : Ws_frame.frame) : unit =
  let mask = Ws_frame.random_mask () in
  write_raw t (Ws_frame.encode ~mask_key:mask f)

let send_text (t : t) (s : string) : unit =
  send_frame t { fin = true; opcode = Text; payload = s }

let send_pong (t : t) ~payload : unit =
  send_frame t { fin = true; opcode = Pong; payload }

let send_close (t : t) ?(code = 1000) ?(reason = "") () : unit =
  if not t.closed then begin
    let payload =
      let b = Bytes.create (2 + String.length reason) in
      Bytes.set b 0 (Char.chr ((code lsr 8) land 0xFF));
      Bytes.set b 1 (Char.chr (code land 0xFF));
      Bytes.blit_string reason 0 b 2 (String.length reason);
      Bytes.to_string b
    in
    (try send_frame t { fin = true; opcode = Close; payload }
     with _ -> ());
    t.closed <- true
  end

(** Read the next application-level message. Transparently responds to
    pings and surfaces close frames as [Close]. Raises [End_of_file]
    after a close handshake has completed in both directions. *)
let rec recv (t : t) : message =
  if t.closed then raise End_of_file;
  let f = Ws_frame.decode (reader_of t.buf) in
  match f.opcode with
  | Text -> Text f.payload
  | Binary -> Binary f.payload
  | Ping -> send_pong t ~payload:f.payload; recv t
  | Pong -> recv t   (* ignore unsolicited pongs *)
  | Close ->
    let code, reason =
      if String.length f.payload >= 2 then
        let c = (Char.code f.payload.[0] lsl 8) lor Char.code f.payload.[1] in
        let r = String.sub f.payload 2 (String.length f.payload - 2) in
        Some c, r
      else None, ""
    in
    send_close t ?code ~reason ();
    Close { code; reason }
  | Continuation | Unknown _ -> recv t

(** --- HTTP Upgrade handshake --- *)

let header_line k v = k ^ ": " ^ v ^ "\r\n"

let build_handshake ~host ~path ~key ~extra_headers =
  let buf = Buffer.create 256 in
  Buffer.add_string buf ("GET " ^ path ^ " HTTP/1.1\r\n");
  Buffer.add_string buf (header_line "Host" host);
  Buffer.add_string buf (header_line "Upgrade" "websocket");
  Buffer.add_string buf (header_line "Connection" "Upgrade");
  Buffer.add_string buf (header_line "Sec-WebSocket-Key" key);
  Buffer.add_string buf (header_line "Sec-WebSocket-Version" "13");
  List.iter (fun (k, v) -> Buffer.add_string buf (header_line k v))
    extra_headers;
  Buffer.add_string buf "\r\n";
  Buffer.contents buf

let read_response_headers (buf : Eio.Buf_read.t) : int * (string * string) list =
  let status_line = Eio.Buf_read.line buf in
  let code =
    match String.split_on_char ' ' status_line with
    | _ :: c :: _ -> (try int_of_string c with _ -> 0)
    | _ -> 0
  in
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
  code, loop []

let find_header hs k =
  List.assoc_opt (String.lowercase_ascii k) hs

(** Connect to a `wss://` URL, perform the WS handshake, return a live
    client. The caller is expected to register the returned [t] under
    an [Eio.Switch.t] that cancels on teardown (we don't [close] the
    underlying flow here — the switch does). *)
let connect
    ~env
    ~sw
    ~uri
    ?(extra_headers = [])
    ?authenticator
    () : t =
  let host =
    match Uri.host uri with
    | Some h -> h | None -> invalid_arg "ws_client: uri missing host"
  in
  let port = match Uri.port uri with
    | Some p -> p
    | None ->
      match Uri.scheme uri with Some "wss" -> 443 | _ -> 80
  in
  let path = match Uri.path_and_query uri with "" -> "/" | p -> p in
  let net = Eio.Stdenv.net env in
  let addr =
    Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port)
    |> function
    | [] -> failwith ("ws_client: cannot resolve " ^ host)
    | a :: _ -> a
  in
  let raw = Eio.Net.connect ~sw net addr in
  let flow : Eio.Flow.two_way_ty Eio.Resource.t =
    match Uri.scheme uri with
    | Some "wss" ->
      let authenticator = match authenticator with
        | Some a -> a
        | None -> fun ?ip:_ ~host:_ _ -> Ok None
      in
      let tls_cfg =
        match Tls.Config.client ~authenticator () with
        | Ok c -> c
        | Error (`Msg m) -> failwith ("ws_client: tls config: " ^ m)
      in
      let host_opt =
        match Domain_name.of_string host with
        | Ok d ->
          (match Domain_name.host d with Ok h -> Some h | _ -> None)
        | Error _ -> None
      in
      let tls = Tls_eio.client_of_flow ?host:host_opt tls_cfg raw in
      (tls :> Eio.Flow.two_way_ty Eio.Resource.t)
    | _ ->
      (raw :> Eio.Flow.two_way_ty Eio.Resource.t)
  in
  let key = Ws_frame.random_key () in
  let handshake = build_handshake ~host ~path ~key ~extra_headers in
  Eio.Flow.copy_string handshake flow;
  let buf = Eio.Buf_read.of_flow flow ~max_size:65536 in
  let code, headers = read_response_headers buf in
  if code <> 101 then
    failwith (Printf.sprintf "ws_client: handshake failed, status %d" code);
  let expected = Ws_frame.accept_token key in
  (match find_header headers "sec-websocket-accept" with
   | Some v when v = expected -> ()
   | Some v ->
     failwith (Printf.sprintf
       "ws_client: bad Sec-WebSocket-Accept (got %s, want %s)" v expected)
   | None -> failwith "ws_client: no Sec-WebSocket-Accept in response");
  { flow; buf; mutex = Eio.Mutex.create (); closed = false }
