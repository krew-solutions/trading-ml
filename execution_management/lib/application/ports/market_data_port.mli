(** Hexagonal port: top-of-book + realised-volatility feed.

    Consumed by mark-to-market projections and (when the adaptive
    variant ships) the Implementation-Shortfall strategy for
    re-routing on adverse price movement. Subscribers attach
    per-instrument; the adapter invokes the callback on every
    new {!Market_data_quote.t}. *)

module type S = sig
  type t
  (** Adapter instance — holds the subscriber registry. *)

  type subscription

  val subscribe :
    t ->
    instrument:Core.Instrument.t ->
    on_quote:(Execution_management.Order_ticket.Values.Market_data_quote.t -> unit) ->
    subscription

  val unsubscribe : t -> subscription -> unit
end
