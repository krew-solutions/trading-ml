(** Domain event: the kill switch tripped on an equity update —
    submissions stay halted until {!Kill_switch.reset} is called.
    Translated by a domain-event handler into
    {!Kill_switch_tripped_integration_event} for telemetry / SSE. *)

type t = {
  peak_equity : Decimal.t;
  current_equity : Decimal.t;
  drawdown : float;
  occurred_at : int64;
}

val make :
  peak_equity:Decimal.t ->
  current_equity:Decimal.t ->
  drawdown:float ->
  occurred_at:int64 ->
  t
