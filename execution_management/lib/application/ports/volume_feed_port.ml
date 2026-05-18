module type S = sig
  type t
  type subscription

  val subscribe :
    t ->
    instrument:Core.Instrument.t ->
    timeframe:string ->
    on_bar:(Execution_management.Order_ticket.Values.Volume_bar.t -> unit) ->
    subscription

  val unsubscribe : t -> subscription -> unit
end
