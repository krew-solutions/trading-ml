(** Hexagonal port: top-of-book + realised-volatility feed.

    Consumed by the Implementation-Shortfall strategy for adaptive
    re-routing on adverse price movement (deferred refinement;
    today IS ignores [Price_quote] inputs). The infrastructure
    adapter today is [Disabled]. *)

module type S = sig
  type subscription

  val subscribe :
    instrument:Core.Instrument.t ->
    on_quote:
      (Execution_management.Order_ticket.Values.Market_data_quote.t -> unit) ->
    subscription

  val unsubscribe : subscription -> unit
end
