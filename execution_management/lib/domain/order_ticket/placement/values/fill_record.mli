(** A single fill observation on a Placement — the venue executed
    [quantity] units at [price], charging [fee]. Multiple
    Fill_records accumulate against one Placement for partial
    fills.

    Invariants:
    - [quantity > 0] (a "fill" of zero is not a fill);
    - [price ≥ 0] (negative quotes are not domain-valid);
    - [fee ≥ 0]. *)

(*@ function dec_raw (d : Decimal.t) : integer *)

type t = private {
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
  ts : int64;
}

val make :
  quantity:Decimal.t -> price:Decimal.t -> fee:Decimal.t -> ts:int64 -> t
(** Raises [Invalid_argument] when any invariant is violated. *)
(*@ r = make ~quantity ~price ~fee ~ts
    requires dec_raw quantity > 0
    requires dec_raw price >= 0
    requires dec_raw fee >= 0
    ensures dec_raw r.quantity = dec_raw quantity
    ensures dec_raw r.price = dec_raw price
    ensures dec_raw r.fee = dec_raw fee
    ensures r.ts = ts *)
