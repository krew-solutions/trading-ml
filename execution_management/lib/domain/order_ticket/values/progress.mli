(** Cumulative ticket-level fill progress. Aggregates fills
    across all Placements of an OrderTicket; the aggregate root
    uses [Progress.t] as the single source of truth for "how much
    of the trader's intent have we executed in the world".

    Invariants:
    - [cumulative_filled ≥ 0];
    - [cumulative_filled ≤ total_quantity] (the aggregate refuses
      to apply a fill that would push past total);
    - [total_fees ≥ 0]. *)

(*@ function dec_raw (d : Decimal.t) : integer *)

type t = private {
  total_quantity : Decimal.t;
  cumulative_filled : Decimal.t;
  total_fees : Decimal.t;
}

val empty : total_quantity:Decimal.t -> t
(*@ r = empty ~total_quantity
    requires dec_raw total_quantity > 0
    ensures dec_raw r.total_quantity = dec_raw total_quantity
    ensures dec_raw r.cumulative_filled = 0
    ensures dec_raw r.total_fees = 0 *)

val apply_fill : t -> fill:Placement.Values.Fill_record.t -> t
(** Add a fill to the cumulative totals. Raises [Invalid_argument]
    if it would push cumulative_filled past total_quantity (the
    aggregate enforces this at its boundary, so a violation
    indicates a bug — never a normal outcome). *)
(*@ r = apply_fill t ~fill
    requires dec_raw t.cumulative_filled + dec_raw fill.Placement.Values.Fill_record.quantity
             <= dec_raw t.total_quantity
    ensures dec_raw r.total_quantity = dec_raw t.total_quantity
    ensures dec_raw r.cumulative_filled
              = dec_raw t.cumulative_filled + dec_raw fill.Placement.Values.Fill_record.quantity
    ensures dec_raw r.total_fees = dec_raw t.total_fees + dec_raw fill.Placement.Values.Fill_record.fee *)

val remaining_quantity : t -> Decimal.t
(*@ r = remaining_quantity t
    ensures dec_raw r = dec_raw t.total_quantity - dec_raw t.cumulative_filled *)

val is_fully_filled : t -> bool
(*@ r = is_fully_filled t
    ensures r <-> dec_raw t.cumulative_filled = dec_raw t.total_quantity *)
