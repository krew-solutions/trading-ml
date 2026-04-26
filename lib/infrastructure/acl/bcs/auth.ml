(** BCS OAuth2 / Keycloak auth.
    Flow:
      1. Initial refresh-token is read from the provided
         {!Token_store.t} (env var, file, keyring — caller's choice).
      2. [current] POSTs [token_endpoint] with
           grant_type=refresh_token&refresh_token=…&client_id=…
         in [application/x-www-form-urlencoded] and parses both
         [access_token] + [expires_in] *and* the rotated
         [refresh_token] (Keycloak rotates on every exchange when the
         realm has rotation enabled). The new refresh-token is
         [Token_store.save]d immediately so subsequent exchanges use
         the fresh value.
      3. The access_token goes into [Authorization: Bearer …]; it's
         cached in memory until [expires_in - margin] seconds.

    Mutex discipline identical to [Finam.Auth]: stdlib mutex held only
    for state-swap, never across the HTTP round-trip, so concurrent
    Eio fibers can't self-deadlock. *)

type jwt = { token : string; expires_at : float }

type t = {
  cfg : Config.t;
  token_store : Token_store.t;
  transport : Http_transport.t;
  mutex : Mutex.t;
  mutable state : jwt option;
}

let make ~transport ~cfg ~token_store =
  { cfg; token_store; transport; mutex = Mutex.create (); state = None }

let now () = Unix.gettimeofday ()
let margin = 30.0

let urlencode_form fields =
  fields
  |> List.map (fun (k, v) ->
      Uri.pct_encode ~component:`Userinfo k ^ "=" ^ Uri.pct_encode ~component:`Userinfo v)
  |> String.concat "&"

let http_refresh t : jwt =
  let current_refresh =
    match Token_store.load t.token_store with
    | Some s -> s
    | None ->
        failwith
          "BCS Auth: refresh-token store is empty (set BCS_SECRET or persist one in the \
           store)"
  in
  let body =
    urlencode_form
      [
        ("grant_type", "refresh_token");
        ("refresh_token", current_refresh);
        ("client_id", t.cfg.client_id);
      ]
  in
  let resp =
    t.transport
      {
        meth = `POST;
        url = t.cfg.token_endpoint;
        headers =
          [
            ("Content-Type", "application/x-www-form-urlencoded");
            ("Accept", "application/json");
          ];
        body = Some body;
      }
  in
  if resp.status < 200 || resp.status >= 300 then
    failwith
      (Printf.sprintf "BCS Auth: token endpoint returned %d: %s" resp.status resp.body);
  let j = Yojson.Safe.from_string resp.body in
  let open Yojson.Safe.Util in
  let token =
    match member "access_token" j with
    | `String s -> s
    | _ -> failwith ("BCS Auth: no access_token in " ^ resp.body)
  in
  let expires_in =
    match member "expires_in" j with
    | `Int n -> float_of_int n
    | `Float f -> f
    | _ -> 300.0 (* conservative fallback *)
  in
  (* Persist the rotated refresh-token. Keycloak omits the field when
     rotation is disabled for the realm, in which case [current_refresh]
     stays valid and there's nothing to save. *)
  (match member "refresh_token" j with
  | `String s when s <> "" && s <> current_refresh -> Token_store.save t.token_store s
  | _ -> ());
  { token; expires_at = now () +. expires_in }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

(** Force-drop the cached access_token so the next [current] refreshes.
    Called by the HTTP retry layer on 401. *)
let invalidate (t : t) : unit = with_lock t (fun () -> t.state <- None)

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
