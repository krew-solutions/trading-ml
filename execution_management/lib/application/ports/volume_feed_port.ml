module type S = sig
  type subscription

  val subscribe :
    instrument:Core.Instrument.t ->
    on_bar:(Execution_management.Order_ticket.Values.Volume_bar.t -> unit) ->
    subscription

  val unsubscribe : subscription -> unit
end
