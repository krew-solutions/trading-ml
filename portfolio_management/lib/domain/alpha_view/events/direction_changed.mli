(** Domain event: an alpha source's directional view on an instrument
    flipped. Emitted by {!Alpha_view.define} only when the new
    direction differs from the previously held one — same-direction
    redefinitions update strength/price silently without an event.

    Carries both [previous_direction] and [new_direction] for
    downstream observers (e.g. diagnostics that flag flapping
    sources). [strength] and [price] are the freshly observed values
    that triggered the flip. *)

type t = {
  alpha_source_id : Common.Alpha_source_id.t;
  instrument : Core.Instrument.t;
  previous_direction : Common.Direction.t;
  new_direction : Common.Direction.t;
  strength : float;
  price : Decimal.t;
  occurred_at : int64;
}
