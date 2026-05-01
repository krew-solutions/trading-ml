(** Pending trade Entity — cash/qty reserved but not yet applied.
    Identified by [id]; lifecycle is
    [reserve → commit_partial_fill* → commit_fill | release]. Lives
    inside the [Portfolio] aggregate, so the parent aggregate is the
    sole transactional consistency boundary. *)

(*@ function dec_raw (d : Decimal.t) : integer *)
(** Local alias for [Decimal.t]'s scaled-integer projection. See the
    matching note in [core/candle.mli] — Gospel 0.3.1 doesn't carry
    [model] declarations across files, so each consumer restates it. *)

type t = {
  id : int;
  side : Core.Side.t;
  instrument : Core.Instrument.t;
  quantity : Decimal.t;
      (** Remaining reserved quantity — decreases on partial fills,
      hits zero on a final commit. *)
  per_unit_cash : Decimal.t;
      (** For Buy: per-unit cash impact including slippage buffer and
      fee estimate — set at construction and never changes. For Sell
      it's zero (sells free cash, they don't consume it). *)
}
(** A pending trade — cash/qty reserved but not yet applied. Scales
    down on partial fills: [quantity] is the *remaining* reserved
    amount, [per_unit_cash] is immutable so proration stays linear. *)

val reserved_cash : t -> Decimal.t
(** [quantity × per_unit_cash]. Earmarked cash still pending
    (drops as partial fills commit). *)

val reserved_qty : t -> Decimal.t
(** [quantity] for a Sell reservation, [Decimal.zero] for a Buy.
    Earmarked position qty locking out further sells on the same
    instrument. *)
(*@ q = reserved_qty r
    ensures dec_raw q =
            (match r.side with
             | Core.Side.Buy -> 0
             | Core.Side.Sell -> dec_raw r.quantity) *)

val per_unit_cash_of :
  side:Core.Side.t ->
  price:Decimal.t ->
  slippage_buffer:Decimal.t ->
  fee_rate:Decimal.t ->
  Decimal.t
(** Per-unit cash impact of a future fill for reservation purposes.
    For Buy: [price × (1 + slippage_buffer) + price × fee_rate]. For
    Sell: zero (sells free cash). Used as a factory helper for
    [t.per_unit_cash] — immutable after construction so partial-fill
    proration just scales by remaining quantity. [slippage_buffer]
    and [fee_rate] are {!Decimal.t} (not [float]) so the
    arithmetic stays in the verified Decimal domain end-to-end. *)
