module T = Trading_config_t
module J = Trading_config_j

let read_file path =
  let ic = open_in path in
  let len = in_channel_length ic in
  let s = really_input_string ic len in
  close_in ic;
  s

let load_file path : T.t = J.t_of_string (read_file path)

let load_file_opt path : T.t option =
  if Sys.file_exists path then try Some (load_file path) with _ -> None else None

let resolve_local_path ~local_path ~env_var : string option =
  match local_path with
  | Some _ -> local_path
  | None -> (
      let env_path =
        match env_var with
        | None -> None
        | Some name -> (
            match Sys.getenv_opt name with
            | Some p when String.length p > 0 -> Some p
            | _ -> None)
      in
      match env_path with
      | Some _ -> env_path
      | None ->
          let conventional = "config/local.config.json" in
          if Sys.file_exists conventional then Some conventional else None)

(* Build a sparse Broker overlay carrying only the credentials
   the env vars contributed. Returns [None] if no relevant env
   vars are set; otherwise returns a [Some broker] that the
   surrounding layered merge will use to *replace* the broker
   variant whole. This is a deliberate trade-off: env vars set
   credentials on a specific broker; the broker variant itself
   should be selected by file or CLI. We honour env vars only
   when the resolved base config already picks the matching
   variant — otherwise an env-var setting for Finam credentials
   on a BCS-configured book would silently swap the broker. *)
let env_broker_overlay (base : T.broker option) : T.broker option =
  match base with
  | Some (`Finam creds) ->
      let merged : T.finam_credentials =
        {
          account_id =
            (match Sys.getenv_opt "FINAM_ACCOUNT_ID" with
            | Some _ as s -> s
            | None -> creds.account_id);
          secret =
            (match Sys.getenv_opt "FINAM_SECRET" with
            | Some _ as s -> s
            | None -> creds.secret);
        }
      in
      Some (`Finam merged)
  | Some (`Bcs creds) ->
      let merged : T.bcs_credentials =
        {
          client_id =
            (match Sys.getenv_opt "BCS_CLIENT_ID" with
            | Some _ as s -> s
            | None -> creds.client_id);
          secret_seed =
            (match Sys.getenv_opt "BCS_SECRET" with
            | Some _ as s -> s
            | None -> creds.secret_seed);
        }
      in
      Some (`Bcs merged)
  | other -> other

let parse_log_level (s : string) : T.log_level option =
  match String.lowercase_ascii s with
  | "debug" -> Some `Debug
  | "info" -> Some `Info
  | "warning" | "warn" -> Some `Warning
  | "error" -> Some `Error
  | _ -> None

let env_logging_overlay (base : T.logging option) : T.logging option =
  match Sys.getenv_opt "LOG_LEVEL" with
  | None -> base
  | Some s -> (
      match parse_log_level s with
      | None -> base
      | Some level -> (
          match base with
          | None -> Some { level = Some level }
          | Some _ -> Some { level = Some level }))

let apply_env_overrides (cfg : T.t) : T.t =
  {
    cfg with
    broker = env_broker_overlay cfg.broker;
    logging = env_logging_overlay cfg.logging;
  }

let load
    ~(default_path : string)
    ?(local_path : string option)
    ?(env_var : string option)
    ?(cli_overrides : T.t option)
    () : T.t =
  let default = load_file default_path in
  let after_local =
    match resolve_local_path ~local_path ~env_var with
    | None -> default
    | Some p -> (
        match load_file_opt p with
        | None -> default
        | Some local -> Merger.merge default local)
  in
  let after_env = apply_env_overrides after_local in
  match cli_overrides with
  | None -> after_env
  | Some cli -> Merger.merge after_env cli
