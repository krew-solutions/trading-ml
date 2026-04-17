(** Resilient WebSocket connection: auto-reconnect with exponential
    backoff + periodic heartbeat ping. Broker-agnostic — the caller
    injects [connect], [on_text], and [on_disconnect] callbacks.

    Lifecycle:
    1. [create] spawns the reader + heartbeat fibers.
    2. On disconnect: waits [backoff] → calls [connect] → calls
       [on_reconnect] (for resubscription) → resumes reader.
    3. [close] stops all fibers and closes the socket.

    Thread-safe: [send] serialises writes via a mutex. *)

type config = {
  label : string;
  ping_interval : float;
  max_backoff : float;
  connect : unit -> Client.t;
  on_text : string -> unit;
  on_reconnect : unit -> unit;
}

type t

val create :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  config:config ->
  t

val send : t -> string -> unit
val close : t -> unit
val is_alive : t -> bool
