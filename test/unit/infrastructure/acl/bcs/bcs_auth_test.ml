(** Unit tests for [Bcs.Auth]: refresh-token → access-token exchange,
    caching semantics, invalidation. Driven by a fake
    [Http_transport.t] so no network is involved. *)

open Bcs

(** Base64url without padding. Matches what Keycloak emits. *)
let b64url s =
  Base64.encode_string s |> String.to_seq
  |> Seq.filter (fun c -> c <> '=')
  |> String.of_seq
  |> String.map (function
    | '+' -> '-'
    | '/' -> '_'
    | c -> c)

(** A minimal JWT-like string. [exp_epoch] isn't actually parsed by
    [Auth] (BCS uses [expires_in] from the token response instead), so
    the payload only needs to be valid base64url JSON. *)
let make_jwt ~exp_epoch =
  let header = b64url {|{"alg":"HS256","typ":"JWT"}|} in
  let payload = b64url (Printf.sprintf {|{"exp":%d}|} exp_epoch) in
  let sig_ = b64url "sig" in
  Printf.sprintf "%s.%s.%s" header payload sig_

let token_body ~access ~expires_in =
  Yojson.Safe.to_string
    (`Assoc [ ("access_token", `String access); ("expires_in", `Int expires_in) ])

let make_cfg () =
  Config.make ~token_endpoint:(Uri.of_string "https://example.test/token") ()

let make_store ~refresh_token = Token_store.memory ~initial:refresh_token ()

let test_initial_call_posts_form_encoded () =
  let requests = ref [] in
  let exp = int_of_float (Unix.gettimeofday ()) + 600 in
  let tok = make_jwt ~exp_epoch:exp in
  let transport : Http_transport.t =
   fun req ->
    requests := req :: !requests;
    { status = 200; body = token_body ~access:tok ~expires_in:600 }
  in
  let cfg = make_cfg () in
  let auth =
    Auth.make ~transport ~cfg ~token_store:(make_store ~refresh_token:"REFRESH")
  in
  let fetched = Auth.current auth in
  Alcotest.(check string) "access_token returned" tok fetched;
  Alcotest.(check int) "one request" 1 (List.length !requests);
  let req = List.hd !requests in
  Alcotest.(check bool) "POST" true (req.meth = `POST);
  Alcotest.(check string)
    "content-type" "application/x-www-form-urlencoded"
    (List.assoc "Content-Type" req.headers);
  let body = Option.value req.body ~default:"" in
  Alcotest.(check bool)
    "body has grant_type=refresh_token" true
    (String.length body > 0
    &&
      try
        let _ = Str.search_forward (Str.regexp "grant_type=refresh_token") body 0 in
        true
      with Not_found -> false);
  Alcotest.(check bool)
    "body has refresh_token=REFRESH" true
    (try
       let _ = Str.search_forward (Str.regexp "refresh_token=REFRESH") body 0 in
       true
     with Not_found -> false);
  Alcotest.(check bool)
    "body has client_id" true
    (try
       let _ = Str.search_forward (Str.regexp "client_id=trade-api-write") body 0 in
       true
     with Not_found -> false)

let test_caches_until_expiry () =
  let requests = ref [] in
  let exp = int_of_float (Unix.gettimeofday ()) + 600 in
  let tok = make_jwt ~exp_epoch:exp in
  let transport : Http_transport.t =
   fun req ->
    requests := req :: !requests;
    { status = 200; body = token_body ~access:tok ~expires_in:600 }
  in
  let cfg = make_cfg () in
  let auth = Auth.make ~transport ~cfg ~token_store:(make_store ~refresh_token:"R") in
  let _ = Auth.current auth in
  let _ = Auth.current auth in
  let _ = Auth.current auth in
  Alcotest.(check int) "single HTTP call across reads" 1 (List.length !requests)

let test_invalidate_triggers_reauth () =
  let requests = ref [] in
  let tok = make_jwt ~exp_epoch:(int_of_float (Unix.gettimeofday ()) + 600) in
  let transport : Http_transport.t =
   fun req ->
    requests := req :: !requests;
    { status = 200; body = token_body ~access:tok ~expires_in:600 }
  in
  let cfg = make_cfg () in
  let auth = Auth.make ~transport ~cfg ~token_store:(make_store ~refresh_token:"R") in
  let _ = Auth.current auth in
  Auth.invalidate auth;
  let _ = Auth.current auth in
  Alcotest.(check int) "invalidate forces a second POST" 2 (List.length !requests)

let test_refresh_when_expiry_near () =
  (* First response advertises expires_in=0 so cache is immediately stale. *)
  let requests = ref [] in
  let tok1 = make_jwt ~exp_epoch:(int_of_float (Unix.gettimeofday ()) - 10) in
  let tok2 = make_jwt ~exp_epoch:(int_of_float (Unix.gettimeofday ()) + 600) in
  let transport : Http_transport.t =
   fun req ->
    requests := req :: !requests;
    let tok = if List.length !requests = 1 then tok1 else tok2 in
    let expires_in = if List.length !requests = 1 then 0 else 600 in
    { status = 200; body = token_body ~access:tok ~expires_in }
  in
  let cfg = make_cfg () in
  let auth = Auth.make ~transport ~cfg ~token_store:(make_store ~refresh_token:"R") in
  let _ = Auth.current auth in
  let _ = Auth.current auth in
  Alcotest.(check int) "stale cache refreshes" 2 (List.length !requests)

let tests =
  [
    ("POSTs token endpoint form-encoded", `Quick, test_initial_call_posts_form_encoded);
    ("caches until expiry", `Quick, test_caches_until_expiry);
    ("invalidate triggers reauth", `Quick, test_invalidate_triggers_reauth);
    ("refresh when cache stale", `Quick, test_refresh_when_expiry_near);
  ]
