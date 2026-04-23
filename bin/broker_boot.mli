(** Shared CLI plumbing for the [trading] executables: argument
    parsing helpers, broker credential resolution, and the "open
    broker" boilerplate that turns [--broker finam|bcs|synthetic]
    + creds into a live {!Broker.client} (and the concrete REST
    handle for server-side wiring). Both [main.ml] and
    [export_training_data.ml] consume this. *)

val arg_value : string -> string list -> string option
(** [arg_value "--foo" argv] — value following [--foo] in the
    argument list, or [None] if the flag is absent. *)

val broker_env_prefix : string -> string
(** [broker_env_prefix broker_id] — env-var prefix for the given
    broker ("BCS", "FINAM"). Used to locate credentials like
    [<PREFIX>_SECRET] / [<PREFIX>_ACCOUNT_ID]. *)

(** Result of opening a broker: the port-compatible {!Broker.client}
    plus the concrete REST handle for live brokers (the server's
    WS bridge needs it). Synthetic has no REST side. *)
type opened =
  | Opened_finam     of { client : Broker.client; rest : Finam.Rest.t }
  | Opened_bcs       of { client : Broker.client; rest : Bcs.Rest.t }
  | Opened_synthetic of { client : Broker.client }

val opened_client : opened -> Broker.client

val open_finam :
  env:Eio_unix.Stdenv.base ->
  secret:string ->
  account:string option ->
  opened
(** Requires a valid secret + account (errors to stderr + exits
    with status 2 if [account] is [None]). *)

val open_bcs :
  env:Eio_unix.Stdenv.base ->
  secret:string option ->
  account:string option ->
  client_id:string option ->
  opened
(** Reads the BCS refresh-token from the [Token_store] chain
    (--secret seed → persistent file → BCS_SECRET env). *)

val open_synthetic : unit -> opened
