(** Placement entity — a single broker-bound slice of an
    OrderTicket. One ticket fans out N placements according to its
    Strategy. Each Placement has its own status lifecycle and
    accumulates its own fills; the OrderTicket aggregate
    aggregates across placements via [Progress.t].

    Lifecycle (linear):
      Pending → Working → {Filled | Rejected | Unreachable | Cancelled}

    Invariants:
    - [cumulative_filled ≤ requested_quantity];
    - terminal status is absorbing (transitions out of it are
      ignored — the aggregate enforces idempotency at its boundary). *)

module Values : module type of Values

(*@ function dec_raw (d : Decimal.t) : integer *)

type t = private {
  id : Values.Placement_id.t;
  requested_quantity : Decimal.t;
  cumulative_filled : Decimal.t;
  status : Values.Placement_status.t;
  kind : Values.Order_kind.t;
  tif : Values.Tif.t;
}

val pending :
  id:Values.Placement_id.t ->
  requested_quantity:Decimal.t ->
  kind:Values.Order_kind.t ->
  tif:Values.Tif.t ->
  t
(*@ p = pending ~id ~requested_quantity ~kind ~tif
    requires dec_raw requested_quantity > 0
    ensures dec_raw p.requested_quantity = dec_raw requested_quantity
    ensures dec_raw p.cumulative_filled = 0
    ensures p.status = Values.Placement_status.Pending *)

val acknowledge : t -> t
val apply_fill : t -> fill:Values.Fill_record.t -> t

(*@ p' = apply_fill p ~fill
    requires dec_raw p.cumulative_filled + dec_raw fill.Values.Fill_record.quantity
             <= dec_raw p.requested_quantity *)
val reject : t -> t
val unreachable : t -> t
val cancel : t -> t

val remaining_quantity : t -> Decimal.t
val is_terminal : t -> bool
