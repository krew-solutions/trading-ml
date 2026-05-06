module type S = sig
  type config
  type state

  val name : string
  val init : config -> state

  val on_bar :
    state ->
    instrument:Core.Instrument.t ->
    candle:Core.Candle.t ->
    state * Common.Target_proposal.t option
end
