(** Composite strategy: combines N child strategies under a voting
    policy. Implements [Strategy.S] so it's indistinguishable from a
    leaf — can be backtested, registered, or nested.

    Policies:
    - [Unanimous] — all children must agree (Hold = "no").
    - [Majority]  — >50% of all children.
    - [Any]       — at least one active voter.
    - [Adaptive]  — Sharpe-weighted ensemble: each child's vote is
      scaled by its rolling Sharpe ratio over [window] realized
      returns. Children that have been profitable get more influence;
      poorly-performing children are down-weighted toward zero. When
      all Sharpes are non-positive, falls back to equal weights.
    - [Learned]   — caller-injected prediction function that scores
      (child_signals, candle, market_context) → P(profitable).
      The composite itself has no ML dependency; the logistic
      regression model (or any other scorer) is wired in at
      construction time via [predict]. Train offline via
      {!Logistic_regression.Trainer.train}, then wrap the resulting
      weights into a [predict] closure. *)

open Core

type predictor =
  signals:Signal.t list ->
  candle:Candle.t ->
  recent_closes:float list ->
  recent_volumes:float list ->
  float
(** Prediction function injected into [Learned] policy.
    Receives child signals, the current candle, and recent
    market-context lists; returns P(profitable long) in [0, 1]. *)

type policy =
  | Unanimous
  | Majority
  | Any
  | Adaptive of { window : int }
  | Learned of { predict : predictor; threshold : float }

type params = { policy : policy; children : Strategy.t list }

type state

val name : string
val default_params : params
val init : params -> state
val on_candle : state -> Instrument.t -> Candle.t -> state * Signal.t
