module type S = sig
  type config

  val name : string

  val size :
    config ->
    book_equity:Decimal.t ->
    mark:(Core.Instrument.t -> Decimal.t) ->
    volatility:(Core.Instrument.t -> Decimal.t option) ->
    Common.Construction_intent.t ->
    Common.Target_proposal.t
end

module Equity_proportional = Equity_proportional
module Volatility_target = Volatility_target
