module type S = sig
  type t
  type subscription

  val subscribe :
    t ->
    instrument:Core.Instrument.t ->
    on_quote:
      (Execution_management.Order_ticket.Values.Market_data_quote.t -> unit) ->
    subscription

  val unsubscribe : t -> subscription -> unit
end
