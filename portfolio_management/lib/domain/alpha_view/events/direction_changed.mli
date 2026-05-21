(** Domain event: an alpha source's directional view on an
    instrument flipped. Emitted by {!Alpha_view.define} only when
    the new direction differs from the previously held one —
    same-direction redefinitions update strength/price silently
    without an event.

    Carries both [previous_direction] and [new_direction] for
    downstream observers (e.g. diagnostics that flag flapping
    sources). [strength] and [price] are the freshly observed
    values that triggered the flip. *)

type t = {
  alpha_source_id : Common.Alpha_source_id.t;
  instrument : Core.Instrument.t;
  previous_direction : Common.Direction.t;
  new_direction : Common.Direction.t;
  strength : float;
  price : Decimal.t;
  occurred_at : int64;
}

val to_construction_intent : t -> book_id:Common.Book_id.t -> Common.Construction_intent.t
(** Pure projection: turns the event into a single-asset
    {!Construction_intent.Scalar} for the supplied subscribing
    [book_id]. One direction flip fans out to as many scalar
    intents as there are books subscribed to this source; each
    call produces an independent intent.

    [strength] is the event's already-clamped value (the
    aggregate guarantees the [\[0, 1\]] invariant on emission)
    promoted to {!Common.Strength.t} at the conversion boundary;
    [source] is built as
    [Common.Source.Alpha_view event.alpha_source_id]. *)
