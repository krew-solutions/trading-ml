(** Hexagonal port: market volume feed.

    Strategies that consume aggregate volume (POV — and a future
    dynamic-VWAP refinement) subscribe per-instrument; the
    adapter delivers each new [Volume_bar.t] by invoking the
    callback. The infrastructure adapter today is [Disabled]
    (registers, never emits) — this makes POV observably blocked
    rather than silently passive when no real feed is wired. *)

module type S = sig
  type subscription
  (** Opaque handle returned by [subscribe]; the caller may pass
      it to [unsubscribe] to stop the flow. The [Disabled]
      adapter returns a no-op handle. *)

  val subscribe :
    instrument:Core.Instrument.t ->
    on_bar:(Execution_management.Order_ticket.Values.Volume_bar.t -> unit) ->
    subscription

  val unsubscribe : subscription -> unit
end
