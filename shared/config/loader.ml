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

(* Treat an empty env var as unset, so a cleared variable does not
   shadow a file/default value (consistent with the broker adapters'
   own env handling). *)
let getenv name =
  match Sys.getenv_opt name with
  | Some s when s <> "" -> Some s
  | _ -> None

(* Per credential field: CLI value wins, else env var, else file/default
   — the documented precedence CLI > env > file (ADR 0031). *)
let pick3 (cli : string option) (env_name : string) (file : string option) : string option
    =
  match cli with
  | Some _ -> cli
  | None -> (
      match getenv env_name with
      | Some _ as e -> e
      | None -> file)

let resolve_finam ~(cli : T.finam_credentials option) ~(file : T.finam_credentials option)
    : T.broker =
  let c f = Option.bind cli f and g f = Option.bind file f in
  `Finam
    {
      T.account_id =
        pick3 (c (fun x -> x.account_id)) "FINAM_ACCOUNT_ID" (g (fun x -> x.account_id));
      secret = pick3 (c (fun x -> x.secret)) "FINAM_SECRET" (g (fun x -> x.secret));
    }

let resolve_bcs ~(cli : T.bcs_credentials option) ~(file : T.bcs_credentials option) :
    T.broker =
  let c f = Option.bind cli f and g f = Option.bind file f in
  `Bcs
    {
      T.client_id =
        pick3 (c (fun x -> x.client_id)) "BCS_CLIENT_ID" (g (fun x -> x.client_id));
      secret_seed =
        pick3 (c (fun x -> x.secret_seed)) "BCS_SECRET" (g (fun x -> x.secret_seed));
    }

let resolve_alor ~(cli : T.alor_credentials option) ~(file : T.alor_credentials option) :
    T.broker =
  let c f = Option.bind cli f and g f = Option.bind file f in
  `Alor
    {
      T.portfolio =
        pick3 (c (fun x -> x.portfolio)) "ALOR_PORTFOLIO" (g (fun x -> x.portfolio));
      secret = pick3 (c (fun x -> x.secret)) "ALOR_SECRET" (g (fun x -> x.secret));
      exchange = pick3 (c (fun x -> x.exchange)) "ALOR_EXCHANGE" (g (fun x -> x.exchange));
    }

(* Resolve the broker: the variant is chosen by the CLI overlay if it
   names one, otherwise by the file/default layer; env vars never select
   a variant (so an env credential cannot silently swap a configured
   broker), only fill its credential fields. See ADR 0031. *)
let resolve_broker ~(file : T.broker option) ~(cli : T.broker option) : T.broker option =
  match (cli, file) with
  | Some (`Finam c), Some (`Finam f) -> Some (resolve_finam ~cli:(Some c) ~file:(Some f))
  | Some (`Finam c), _ -> Some (resolve_finam ~cli:(Some c) ~file:None)
  | Some (`Bcs c), Some (`Bcs f) -> Some (resolve_bcs ~cli:(Some c) ~file:(Some f))
  | Some (`Bcs c), _ -> Some (resolve_bcs ~cli:(Some c) ~file:None)
  | Some (`Alor c), Some (`Alor f) -> Some (resolve_alor ~cli:(Some c) ~file:(Some f))
  | Some (`Alor c), _ -> Some (resolve_alor ~cli:(Some c) ~file:None)
  | Some `Synthetic, _ -> Some `Synthetic
  | None, Some (`Finam f) -> Some (resolve_finam ~cli:None ~file:(Some f))
  | None, Some (`Bcs f) -> Some (resolve_bcs ~cli:None ~file:(Some f))
  | None, Some (`Alor f) -> Some (resolve_alor ~cli:None ~file:(Some f))
  | None, Some `Synthetic -> Some `Synthetic
  | None, None -> None

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
  (* Non-broker fields: the [LOG_LEVEL] env overlay sits below the CLI
     overlay. Server / engine / watchlist have no env layer. *)
  let after_env =
    { after_local with logging = env_logging_overlay after_local.logging }
  in
  let merged =
    match cli_overrides with
    | None -> after_env
    | Some cli -> Merger.merge after_env cli
  in
  (* Broker is resolved explicitly rather than through Merger's
     whole-variant replacement (which would drop env credentials when the
     CLI overlay names the broker): the variant comes from the CLI, else
     the file layer, and each credential field is CLI ?? env ?? file.
     See ADR 0031. *)
  let cli_broker = Option.bind cli_overrides (fun c -> c.T.broker) in
  { merged with broker = resolve_broker ~file:after_local.broker ~cli:cli_broker }
