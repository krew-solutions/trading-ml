(** {!Volume_feed_port.S} adapter that accepts subscriptions and
    never emits — the strategy-side semantic for "volume feed is
    not yet wired".

    Distinct from "no subscription, silent inert": a POV strategy
    whose feed is [Disabled] is observably blocked waiting for a
    [Volume_bar] that never arrives, which surfaces the missing
    infrastructure rather than letting POV silently degenerate
    into Immediate behaviour. *)

include Execution_management_ports.Volume_feed_port.S

val create : unit -> unit
(** No-op placeholder; the adapter is module-level stateless. *)
