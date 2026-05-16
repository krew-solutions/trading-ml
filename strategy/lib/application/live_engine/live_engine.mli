(** Live strategy engine — alpha-only after the M5 evacuation.

    Receives bars from a {!Pipe.Stream.t} (or {!on_bar} for tests),
    feeds them into a {!Strategies.Strategy.t}, and publishes every
    non-Hold {!Common.Signal.t} as a
    {!Strategy_integration_events.Signal_detected_integration_event.t}
    via the supplied port. Order placement, kill-switch, rate-limit,
    reservation lifecycle, drawdown tracking — everything that used
    to live here — moved out:

    - kill-switch / rate-limit → {!Execution_management.Kill_switch}
      / {!Execution_management.Rate_limit};
    - reservation lifecycle →
      {!Execution_management_process_managers.Place_order_pm};
    - position sizing → {!Portfolio_management.Sizing} (via PM's
      alpha-driven domain-event handler);
    - hard pre-trade gate → {!Pre_trade_risk.Assessment}.

    Strategy is a pure alpha emitter now. *)

open Core

type config = {
  strategy : Strategies.Strategy.t;
  instrument : Instrument.t;
  strategy_id : string;
      (** Stable identifier carried in every emitted
        Signal_detected_IE. Maps to PM's [alpha_source_id] on the
        consumer side. *)
}

type t

module Signal_detected = Strategy_integration_events.Signal_detected_integration_event

val make : config:config -> publish_signal_detected:(Signal_detected.t -> unit) -> t

val on_bar : t -> Candle.t -> unit
(** Feed one bar into the engine. Calls [Strategy.on_candle], and on
    a non-Hold signal builds and publishes a
    {!Signal_detected_integration_event.t} via the injected port.
    Re-entrant-safe via an internal mutex; idempotent on
    older-or-equal timestamps. *)

val run : t -> source:Candle.t Pipe.Stream.t -> unit
(** Stream-driver variant: pulls bars from [source] and feeds them
    via {!on_bar}. Blocks (never returns on an effectively-infinite
    source) — invoked inside [Eio.Fiber.fork_daemon]. *)
