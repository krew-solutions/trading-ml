(** Live {!Market_data_port.S} adapter.

    Mirrors {!Broker_volume_feed} for the price channel:
    per-instrument callback registry; the ACL boundary decodes
    broker bus bars into [Market_data_quote.t] (today the close
    price is used as a single last-trade quote, bid = ask =
    close; realised volatility is left at zero — the adapter
    delivers the price channel, a richer top-of-book feed lands
    separately) and pushes them in via {!deliver}.

    Today no domain consumer subscribes — strategies that take
    [Price_quote] input (Implementation Shortfall today, future
    adaptive VWAP) ignore it, and the mark-to-market projection
    is a separate trajectory. The live adapter is wired now so
    a future subscriber can attach without first having to build
    feed infrastructure. *)

type t
type subscription

val create : unit -> t

val subscribe :
  t ->
  instrument:Core.Instrument.t ->
  on_quote:(Execution_management.Order_ticket.Values.Market_data_quote.t -> unit) ->
  subscription

val unsubscribe : t -> subscription -> unit

val deliver :
  t ->
  instrument:Core.Instrument.t ->
  quote:Execution_management.Order_ticket.Values.Market_data_quote.t ->
  unit
