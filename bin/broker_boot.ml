open Core

let arg_value name args =
  let rec find = function
    | k :: v :: _ when k = name -> Some v
    | _ :: rest -> find rest
    | [] -> None
  in
  find args

(** Selects the secret / account env-var prefix per broker. Keeps the
    CLI single-flagged while letting users park credentials for
    multiple brokers side by side. *)
let broker_env_prefix = function
  | "bcs" -> "BCS"
  | _ -> "FINAM"

type opened =
  | Opened_finam of { client : Broker.client; rest : Finam.Rest.t }
  | Opened_bcs of { client : Broker.client; rest : Bcs.Rest.t }
  | Opened_synthetic of { client : Broker.client }

let opened_client = function
  | Opened_finam { client; _ } | Opened_bcs { client; _ } | Opened_synthetic { client } ->
      client

let require_account ~broker_id = function
  | Some a -> a
  | None ->
      Printf.eprintf "--broker %s requires --account (or %s_ACCOUNT_ID)\n" broker_id
        (String.uppercase_ascii broker_id);
      exit 2

let open_finam ~env ~secret ~account : opened =
  let account_id = require_account ~broker_id:"finam" account in
  let cfg = Finam.Config.make ~account_id ~secret () in
  let transport = Http_transport.make_eio ~env in
  let rest = Finam.Rest.make ~transport ~cfg in
  let adapter = Finam.Finam_broker.make ~account_id rest in
  Opened_finam { client = Finam.Finam_broker.as_broker adapter; rest }

(** State path for the persisted BCS refresh-token. [$XDG_STATE_HOME]
    per the XDG Base Directory spec, with [~/.local/state] as the
    documented fallback. The file is [chmod 0o600] by [Token_store]. *)
let bcs_refresh_token_path () =
  let state_home =
    match Sys.getenv_opt "XDG_STATE_HOME" with
    | Some p when p <> "" -> p
    | _ -> Filename.concat (Sys.getenv "HOME") ".local/state"
  in
  let dir = Filename.concat state_home "trading" in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (EEXIST, _, _) -> ());
  Filename.concat dir "bcs-refresh-token"

let open_bcs ~env ~secret ~account ~client_id : opened =
  (* Credential sources, in precedence order:
       1. [--secret VALUE] — seeds the persistent file immediately,
          then reads from it. Use for first-time setup or to force-
          overwrite a stale rotated token.
       2. Persistent file — authoritative once populated. Keycloak
          rotations ([refresh_token] in the /token response) land
          here automatically.
       3. [BCS_SECRET] env var — bootstrap fallback when the file
          is empty. Same env convention as Finam uses.

     [client_id] must match the client under which the refresh-token
     was issued (BCS portal distinguishes [trade-api-read] for data
     and [trade-api-write] for orders). *)
  let file_path = bcs_refresh_token_path () in
  let file_store = Token_store.file ~path:file_path in
  (match secret with
  | Some s -> Token_store.save file_store s
  | None -> ());
  let token_store =
    Token_store.fallback file_store (Token_store.env ~name:"BCS_SECRET")
  in
  let cfg = Bcs.Config.make ?account_id:account ?client_id () in
  let transport = Http_transport.make_eio ~env in
  let rest = Bcs.Rest.make ~transport ~cfg ~token_store in
  Opened_bcs { client = Bcs.Bcs_broker.as_broker rest; rest }

let open_synthetic () : opened =
  let t = Synthetic.Synthetic_broker.make () in
  Opened_synthetic { client = Synthetic.Synthetic_broker.as_broker t }

(** Paginate bars across a date range. Brokers cap per-call bar
    count; we walk [to_ts] backwards in chunks until [from_ts] is
    covered or the broker stops making progress. The returned
    list is chronological with duplicates on chunk boundaries
    removed. *)
let paginate_bars ~fetch ~from_ts ~to_ts : Candle.t list =
  let batches = ref [] in
  let cur_to = ref to_ts in
  let max_iters = 200 in
  let iter = ref 0 in
  let continue = ref true in
  while !continue && !iter < max_iters do
    let batch = fetch ~from_ts ~to_ts:!cur_to in
    (match batch with
    | [] -> continue := false
    | c0 :: _ ->
        let oldest = c0.Candle.ts in
        batches := batch :: !batches;
        if Int64.compare oldest from_ts <= 0 then continue := false
        else if Int64.compare oldest !cur_to >= 0 then continue := false
        else cur_to := Int64.sub oldest 1L);
    incr iter
  done;
  let chrono = List.concat (List.rev !batches) in
  let seen = Hashtbl.create 4096 in
  List.filter
    (fun (c : Candle.t) ->
      if Hashtbl.mem seen c.ts then false
      else (
        Hashtbl.add seen c.ts ();
        true))
    chrono
