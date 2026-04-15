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
  transport : Transport.t;
  base : Uri.t;
  mutex : Mutex.t;           (* stdlib mutex: works both inside and
                                outside an Eio fiber; crit-section is a
                                tiny pointer swap and token parse *)
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
      (* JWT uses base64url without padding. Base64 lib accepts padded
         input, so restore padding and swap URL alphabet. *)
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

(** Refresh the JWT from upstream. Must be called under [t.mutex]. *)
let refresh t : jwt =
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
      (* Some API flavours return {"jwt": "..."} — accept that too. *)
      match member "jwt" j with
      | `String s -> s
      | _ -> failwith ("Finam Auth: no token field in " ^ resp.body)
  in
  let expires_at = match decode_exp token with
    | Some exp -> exp
    | None -> now () +. 600.0   (* conservative 10-minute TTL *)
  in
  let jwt = { token; expires_at } in
  t.state <- Some jwt;
  jwt

(** Safety margin: refresh 30 seconds before the stated expiry to
    avoid races with in-flight requests. *)
let margin = 30.0

let current (t : t) : string =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) (fun () ->
    let need_refresh =
      match t.state with
      | None -> true
      | Some jwt -> jwt.expires_at -. now () < margin
    in
    let jwt =
      if need_refresh then refresh t
      else Option.get t.state
    in
    jwt.token)
