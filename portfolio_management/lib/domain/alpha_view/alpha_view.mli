(** Aggregate root: PM's current alpha-derived view on an instrument
    from a particular source.

    Identity: [(Alpha_source_id, Core.Instrument.t)]. Multiple alpha
    sources may hold simultaneous views on the same instrument; each
    is its own aggregate.

    Financial idiom — «to take a view on X» = «to form a directional
    opinion on X». NOT a CQRS read-model view; this is a domain
    aggregate with invariants:

    - [0 ≤ strength ≤ 1] — input is float, clamped on define;
    - direction-flip detection: a [Direction_changed] domain event is
      emitted only when the new [direction] differs from the held
      one. Same-direction redefinitions silently update
      [strength] / [last_price] / [last_observed_at];
    - idempotency: a redefinition with [occurred_at <=
      last_observed_at] is dropped (late or duplicate readings are
      no-ops). *)

module Events : module type of Events
(** Re-exports of peer subdirs. *)

type t = private {
  alpha_source_id : Common.Alpha_source_id.t;
  instrument : Core.Instrument.t;
  direction : Common.Direction.t;
  strength : float;
  last_price : Decimal.t;
  last_observed_at : int64;
}

val empty : alpha_source_id:Common.Alpha_source_id.t -> instrument:Core.Instrument.t -> t
(** Fresh aggregate: [direction = Flat], [strength = 0.0],
    [last_price = Decimal.zero], [last_observed_at = Int64.min_int].
    Composition root creates one of these on first sighting of an
    [(alpha_source_id, instrument)] pair. *)

val define :
  t ->
  direction:Common.Direction.t ->
  strength:float ->
  price:Decimal.t ->
  occurred_at:int64 ->
  t * Events.Direction_changed.t option
(** Determine current alpha view as the supplied [(direction,
    strength, price)] taken at [occurred_at].

    - [strength] is clamped to [[0.0; 1.0]].
    - If [occurred_at <= self.last_observed_at]: returns [self, None]
      (idempotent; late or replayed readings are dropped).
    - If [direction] differs from [self.direction]: returns the
      updated aggregate plus [Some Direction_changed].
    - If [direction] matches: returns the aggregate with refreshed
      [strength] / [last_price] / [last_observed_at] and [None]. *)
