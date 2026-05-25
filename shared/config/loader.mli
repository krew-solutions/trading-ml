(** Layered loader for {!Trading_config.t}.

    Layers, lowest to highest precedence:

    1. [default_path] (load-bearing — required to exist):
       baseline shape of the configuration, committed to the
       repo as [config/default.config.json].
    2. [local_path] (optional, taken from one of:
       explicit argument, [TRADING_CONFIG] env var, or the
       conventional [config/local.config.json] relative to
       cwd): per-deployment overrides; arbitrary subset of
       fields.
    3. Environment-variable overrides (sparse): credentials
       and runtime-tuning knobs that should not be persisted
       to a file. Recognised names documented per-field below.
    4. Per-invocation overrides (passed in by the binary's
       CLI parser): final say.

    [load] composes the layers via {!Merger.merge} (later wins
    per-field). A missing [default_path] raises; a missing
    [local_path] is a non-fatal skip — that's the whole point
    of layered defaults. *)

val load :
  default_path:string ->
  ?local_path:string ->
  ?env_var:string ->
  ?cli_overrides:Trading_config_t.t ->
  unit ->
  Trading_config_t.t
(** [load ~default_path ?local_path ?env_var ?cli_overrides ()]
    Resolves the final config by composing the four layers.

    [default_path] is mandatory: this is the file we ship in
    the repo with full default values.

    [local_path] specifies the per-deployment overrides file.
    If [None], we fall back to [env_var] (when set and present
    in the process environment) and then to [./config/local.config.json]
    if it exists. A missing file at any of these is a non-error.

    [env_var] is the name of the environment variable that
    provides the local-config path. Conventionally
    ["TRADING_CONFIG"]. If both [local_path] and [env_var] are
    given, [local_path] wins.

    [cli_overrides] is the top-of-stack overlay; constructed
    by the binary's argument parser. Use [Trading_config_t]'s
    record-literal syntax to build a sparse overlay (all
    fields default to [None]).

    Recognised env-var overrides applied at layer 3. Broker
    credentials fill the {b selected} variant — chosen by the CLI
    [--broker] flag if present, else by the file/default layer; env
    never selects a variant, only its credential fields, each resolved
    [CLI ?? env ?? file] (see ADR 0031). An empty value is treated as
    unset.
    - [FINAM_ACCOUNT_ID], [FINAM_SECRET] — credentials when the
      selected variant is [Finam].
    - [BCS_CLIENT_ID], [BCS_SECRET] — credentials when the selected
      variant is [Bcs]. BCS takes no account-id parameter — its
      refresh-token is bound to the account at Keycloak issue time.
    - [ALOR_PORTFOLIO], [ALOR_SECRET], [ALOR_EXCHANGE] — credentials
      when the selected variant is [Alor] ([ALOR_PORTFOLIO] is the
      account/portfolio code, [ALOR_SECRET] the refresh token).
    - [LOG_LEVEL] — overrides [logging.level]. Accepts
      ["debug"], ["info"], ["warning"], ["error"]
      (case-insensitive). *)
