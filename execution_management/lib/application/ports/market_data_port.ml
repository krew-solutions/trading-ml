module type S = sig
  type subscription

  val subscribe :
    instrument:Core.Instrument.t ->
    on_quote:
      (Execution_management.Order_ticket.Values.Market_data_quote.t -> unit) ->
    subscription

  val unsubscribe : subscription -> unit
end
