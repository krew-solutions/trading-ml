(** Abstract store for a long-lived credential (e.g. an OAuth2
    refresh-token) that the caller mutates over time.

    Brokers that rotate their refresh-token on every exchange need
    somewhere to persist the new value; hard-coding a file path into
    the ACL couples secret storage to the OS and makes OS-keyring
    backends (libsecret, KeePassXC, macOS Keychain) awkward to bolt
    on later. [Token_store.t] is a minimal two-operation interface
    that every concrete backend satisfies.

    Semantics:
    - [load] returns [None] when the store has never seen a value
      (first run, no bootstrap). Callers should treat that as
      "credential not yet available" rather than an error.
    - [save] replaces the stored value. Writes are expected to be
      atomic against crashes / concurrent readers for on-disk
      backends; read-only backends may silently no-op. *)

type t

val load : t -> string option
val save : t -> string -> unit

val env : name:string -> t
(** Read-only view of an environment variable. [save] is a no-op —
    the process can't mutate its own parent shell's environment. *)

val memory : ?initial:string -> unit -> t
(** In-process volatile store. Useful for unit tests and for the
    `save`-target half of a [fallback] pair. *)

val file : path:string -> t
(** On-disk store. Writes land atomically via [tmp + rename], with
    mode 0o600 on the temp file so the replacement inherits safe
    permissions. [load] returns [None] if [path] doesn't exist; any
    other I/O error propagates (callers should not silently ignore
    a permissions failure). The parent directory must exist. *)

val fallback : t -> t -> t
(** Composition: [fallback primary secondary] loads from [primary]
    if it has a value, otherwise falls back to [secondary]. [save]
    writes only to [primary] — the bootstrap source stays immutable,
    which is what you want when pairing an env var (bootstrap) with
    a file (persistent). *)
