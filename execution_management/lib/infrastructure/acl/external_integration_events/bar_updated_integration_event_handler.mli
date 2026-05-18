(** ACL handler for broker's [Bar_updated_integration_event].

    Fans out one bar into two ports: the volume-feed delivery
    (consumed by POV today) and the market-data delivery
    (synthesised quote with [bid = ask = close]; available to
    future mark-to-market and adaptive-strategy consumers). The
    handler does no domain work itself — it parses, then pushes
    typed values through the supplied [deliver_*] callbacks.

    Malformed bars are silently dropped: the wire is the source
    of truth for what a valid bar looks like; the EM side never
    raises on a single bad bar. *)

module Vb = Execution_management.Order_ticket.Values.Volume_bar
module Mq = Execution_management.Order_ticket.Values.Market_data_quote

val handle :
  deliver_volume_bar:
    (instrument:Core.Instrument.t -> timeframe:string -> bar:Vb.t -> unit) ->
  deliver_market_data:(instrument:Core.Instrument.t -> quote:Mq.t -> unit) ->
  Bar_updated_integration_event.t ->
  unit
