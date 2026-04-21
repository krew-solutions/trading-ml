(** Finam two-step auth.
    Users hold a long-lived *secret* (issued in the Finam portal). Every
    API call must carry a short-lived *JWT* obtained by POST /v1/sessions
    with that secret. This module caches the JWT, watches its [exp] claim,
    and refreshes transparently before expiry. Consumers (Rest, Ws_bridge)
    call [current] and treat it as opaque. *)

type jwt = {
  token : string;
  expires_at : float;   (* unix epoch seconds *)
}

type t = {
  secret : string;
  transport : Http_transport.t;
  base : Uri.t;
  mutex : Mutex.t;           (* guards [state] ONLY — never held across
                                the HTTP refresh call, otherwise an Eio
                                fiber yielding inside refresh could
                                deadlock another fiber trying to read
                                the cache on the same OS thread *)
  mutable state : jwt option;
}

let make ~secret ~transport ~base = {
  secret; transport; base;
  mutex = Mutex.create ();
  state = None;
}

(** Decode a JWT's payload [exp] claim. Returns [None] on any parsing
    problem; callers fall back to a conservative TTL. *)
let decode_exp (token : string) : float option =
  try
    let parts = String.split_on_char '.' token in
    match parts with
    | _ :: payload_b64 :: _ ->
      let normalise s =
        let s =
          String.map (function '-' -> '+' | '_' -> '/' | c -> c) s
        in
        let pad = (4 - String.length s mod 4) mod 4 in
        s ^ String.make pad '='
      in
      let raw = Base64.decode_exn (normalise payload_b64) in
      let j = Yojson.Safe.from_string raw in
      (match Yojson.Safe.Util.member "exp" j with
       | `Int n -> Some (float_of_int n)
       | `Float f -> Some f
       | _ -> None)
    | _ -> None
  with _ -> None

let now () = Unix.gettimeofday ()

(** Safety margin: refresh 30 seconds before the stated expiry to
    avoid races with in-flight requests. *)
let margin = 30.0

(** Pure HTTP refresh — does NOT touch [t.state] or the mutex. Returns
    the fresh JWT; the caller publishes it under the lock. *)
let http_refresh t : jwt =
  let path = Uri.path t.base ^ "/v1/sessions" in
  let url = Uri.with_path t.base path in
  let body = `Assoc [ "secret", `String t.secret ] in
  let resp =
    t.transport {
      meth = `POST;
      url;
      headers = [
        "Content-Type", "application/json";
        "Accept", "application/json";
      ];
      body = Some (Yojson.Safe.to_string body);
    }
  in
  if resp.status < 200 || resp.status >= 300 then
    failwith (Printf.sprintf
      "Finam Auth: /v1/sessions returned %d: %s" resp.status resp.body);
  let j = Yojson.Safe.from_string resp.body in
  let open Yojson.Safe.Util in
  let token =
    match member "token" j with
    | `String s -> s
    | _ ->
      match member "jwt" j with
      | `String s -> s
      | _ -> failwith ("Finam Auth: no token field in " ^ resp.body)
  in
  let expires_at = match decode_exp token with
    | Some exp -> exp
    | None -> now () +. 600.0
  in
  { token; expires_at }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

(** Force-drop the cached JWT so the next [current] refreshes. Called
    by the HTTP retry layer on 401. *)
let invalidate (t : t) : unit =
  with_lock t (fun () -> t.state <- None)

(** Returns a live JWT.
    Fast path: inspect cache under a tiny critical section.
    Slow path: drop the lock, do the network call, re-acquire briefly
    to publish the result. Concurrent callers whose cache is stale may
    all race through the slow path — the last [state] write wins and
    every caller ends up with a valid token; cheaper than queueing
    behind a lock that spans the network round-trip. *)
let current (t : t) : string =
  let cached =
    with_lock t (fun () ->
      match t.state with
      | Some jwt when jwt.expires_at -. now () >= margin -> Some jwt
      | _ -> None)
  in
  match cached with
  | Some jwt -> jwt.token
  | None ->
    let fresh = http_refresh t in
    with_lock t (fun () -> t.state <- Some fresh);
    fresh.token
