(** Hexagonal port: market volume feed.

    Strategies that consume aggregate volume (POV — and a future
    dynamic-VWAP refinement) subscribe per-instrument plus per
    bar cadence; the adapter delivers each new [Volume_bar.t]
    only to callbacks whose [instrument] and [timeframe] match
    the published bar. *)

module type S = sig
  type t
  (** Adapter instance — holds the subscriber registry. *)

  type subscription
  (** Opaque handle returned by [subscribe]; pass to
      [unsubscribe] to stop the flow. *)

  val subscribe :
    t ->
    instrument:Core.Instrument.t ->
    timeframe:string ->
    on_bar:(Execution_management.Order_ticket.Values.Volume_bar.t -> unit) ->
    subscription

  val unsubscribe : t -> subscription -> unit
end
