(** Unit tests for the two-step Finam auth flow. A fake transport
    captures requests and replies with canned JWT responses; no network. *)

open Finam

(** Build a JWT of the form `header.payload.signature` where only [exp]
    matters to the production code. Components are base64url-encoded
    without padding. *)
let make_jwt ~exp_epoch =
  let b64url s =
    Base64.encode_string s |> String.to_seq
    |> Seq.filter (fun c -> c <> '=')
    |> String.of_seq
    |> String.map (function
      | '+' -> '-'
      | '/' -> '_'
      | c -> c)
  in
  let header = b64url {|{"alg":"HS256","typ":"JWT"}|} in
  let payload = b64url (Printf.sprintf {|{"exp":%d}|} exp_epoch) in
  let sig_ = b64url "sig" in
  Printf.sprintf "%s.%s.%s" header payload sig_

let token_body token = Yojson.Safe.to_string (`Assoc [ ("token", `String token) ])

let test_first_call_triggers_sessions_post () =
  let requests = ref [] in
  let exp = int_of_float (Unix.gettimeofday ()) + 600 in
  let token = make_jwt ~exp_epoch:exp in
  let transport : Http_transport.t =
   fun req ->
    requests := req :: !requests;
    { status = 200; body = token_body token }
  in
  let auth =
    Auth.make ~secret:"SECRET" ~transport ~base:(Uri.of_string "https://example.test")
  in
  let jwt = Auth.current auth in
  Alcotest.(check string) "token passed through" token jwt;
  Alcotest.(check int) "one request fired" 1 (List.length !requests);
  let req = List.hd !requests in
  Alcotest.(check bool) "POST" true (req.meth = `POST);
  let path = Uri.path req.url in
  let suf = "/v1/sessions" in
  Alcotest.(check bool)
    "path ends in /v1/sessions" true
    (String.length path >= String.length suf
    && String.sub path (String.length path - String.length suf) (String.length suf) = suf
    );
  let body =
    match req.body with
    | Some b -> b
    | None -> ""
  in
  let j = Yojson.Safe.from_string body in
  Alcotest.(check string)
    "body carries secret" "SECRET"
    (Yojson.Safe.Util.member "secret" j |> Yojson.Safe.Util.to_string)

let test_jwt_cached_until_expiry () =
  let requests = ref [] in
  let exp = int_of_float (Unix.gettimeofday ()) + 600 in
  let transport : Http_transport.t =
   fun req ->
    requests := req :: !requests;
    { status = 200; body = token_body (make_jwt ~exp_epoch:exp) }
  in
  let auth = Auth.make ~secret:"S" ~transport ~base:(Uri.of_string "https://x.test") in
  let _ = Auth.current auth in
  let _ = Auth.current auth in
  let _ = Auth.current auth in
  Alcotest.(check int) "subsequent calls do not re-POST" 1 (List.length !requests)

let test_refresh_when_expired () =
  let requests = ref [] in
  let past = int_of_float (Unix.gettimeofday ()) - 1 in
  let future = int_of_float (Unix.gettimeofday ()) + 600 in
  let transport : Http_transport.t =
   fun req ->
    requests := req :: !requests;
    let exp = if List.length !requests = 1 then past else future in
    { status = 200; body = token_body (make_jwt ~exp_epoch:exp) }
  in
  let auth = Auth.make ~secret:"S" ~transport ~base:(Uri.of_string "https://x.test") in
  let _ = Auth.current auth in
  let _ = Auth.current auth in
  Alcotest.(check int) "expired token triggers re-auth" 2 (List.length !requests)

let test_accepts_jwt_key_variant () =
  let requests = ref [] in
  let future = int_of_float (Unix.gettimeofday ()) + 600 in
  let token = make_jwt ~exp_epoch:future in
  let transport : Http_transport.t =
   fun req ->
    requests := req :: !requests;
    { status = 200; body = Yojson.Safe.to_string (`Assoc [ ("jwt", `String token) ]) }
  in
  let auth = Auth.make ~secret:"S" ~transport ~base:(Uri.of_string "https://x.test") in
  Alcotest.(check string) "jwt key accepted" token (Auth.current auth)

let tests =
  [
    ("initial call POSTs /v1/sessions", `Quick, test_first_call_triggers_sessions_post);
    ("cached until expiry", `Quick, test_jwt_cached_until_expiry);
    ("refresh when expired", `Quick, test_refresh_when_expired);
    ("accepts {jwt: ...} body variant", `Quick, test_accepts_jwt_key_variant);
  ]
