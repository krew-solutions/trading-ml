(** Immutable portfolio: cash + map of open positions + outstanding
    reservations.

    Reservations are pending buy/sell intents whose cash/qty impact
    has been *committed to availability* but not yet *applied to
    cash/positions*. They exist because live brokers acknowledge
    orders and fill them at different times — between "we sent the
    order" and "broker reports the fill", the funds must be treated
    as unavailable (otherwise the strategy can happily send a second
    order that would collectively overspend).

    Backtest doesn't have that latency gap, so it does
    [reserve → commit_fill] atomically per tick; Live does
    [reserve → broker RTT → commit_fill] with reconciliation. Same
    API, different timing.

    Gospel preconditions on the transition operations document
    the safety obligations callers must satisfy. *)

(** Snapshot of an open trading position. *)
type position = {
  instrument : Core.Instrument.t;
  quantity : Core.Decimal.t;   (** signed: positive = long, negative = short *)
  avg_price : Core.Decimal.t;  (** VWAP entry price *)
}

(** A pending trade — cash/qty reserved but not yet applied. *)
type reservation = {
  id : int;
  side : Core.Side.t;
  instrument : Core.Instrument.t;
  reserved_cash : Core.Decimal.t;
  (** Cash earmarked for this reservation — for Buy this is
      [qty × price × (1 + slippage_buffer) + fee_estimate], for
      Sell it's zero (sells free cash, they don't consume it). *)
  reserved_qty : Core.Decimal.t;
  (** Quantity of position earmarked — for Sell this is the absolute
      quantity being closed/flipped, for Buy it's zero. *)
}

type t = private {
  cash : Core.Decimal.t;
  positions : (Core.Instrument.t * position) list;
  realized_pnl : Core.Decimal.t;
  reservations : reservation list;
}

val empty : cash:Core.Decimal.t -> t
(*@ p = empty ~cash
    ensures p.positions = []
    ensures p.reservations = [] *)

val position : t -> Core.Instrument.t -> position option

val fill :
  t ->
  instrument:Core.Instrument.t ->
  side:Core.Side.t ->
  quantity:Core.Decimal.t ->
  price:Core.Decimal.t ->
  fee:Core.Decimal.t ->
  t
(** Direct fill without reservation — used by the synthetic-fill
    path (Backtest, Paper) for code that doesn't route through the
    reserve/commit cycle. For the reserved path, use
    [reserve] + [commit_fill].

    Raises [Invalid_argument] on non-positive quantity. *)
(*@ r = fill t ~instrument ~side ~quantity ~price ~fee
    raises Invalid_argument _ -> true *)

val reserve :
  t ->
  id:int ->
  side:Core.Side.t ->
  instrument:Core.Instrument.t ->
  quantity:Core.Decimal.t ->
  price:Core.Decimal.t ->
  slippage_buffer:float ->
  fee_rate:float ->
  t
(** Create a pending reservation identified by [id]. The caller
    chooses [id] — typically a monotonic counter — and uses the
    same [id] for the corresponding [commit_fill] or [release].

    For [Buy]: reserves [qty × price × (1 + slippage_buffer)] cash
    plus a fee estimate [qty × price × fee_rate]; [cash]
    is unchanged, but [available_cash] drops.

    For [Sell]: reserves [qty] units of the instrument's position;
    [positions] is unchanged, but [available_qty] for that
    instrument drops. *)

val commit_fill :
  t ->
  id:int ->
  actual_quantity:Core.Decimal.t ->
  actual_price:Core.Decimal.t ->
  actual_fee:Core.Decimal.t ->
  t
(** Settle reservation [id] with actual broker numbers. Removes the
    reservation and applies a real {!fill} using the actual values.
    If the reservation is absent (already committed or never
    existed), raises [Not_found]. *)

val release : t -> id:int -> t
(** Drop reservation [id] with no other state change — used on
    cancel/reject. No-op if the reservation is absent. *)

val available_cash : t -> Core.Decimal.t
(** [cash - Σ(r.reserved_cash for Buy reservations)]. What the
    strategy can still spend without overlapping with inflight
    orders. *)

val available_qty : t -> Core.Instrument.t -> Core.Decimal.t
(** Signed position quantity after subtracting reservations for
    that instrument's pending sells (resp. buys for short covers).
    Returns [Decimal.zero] if there's no position and no
    reservation. *)

val equity : t -> (Core.Instrument.t -> Core.Decimal.t option) -> Core.Decimal.t
(** Mark-to-market equity = cash + Σ quantity·mark_price.
    Reservations are ignored — equity reflects only what's been
    actually cashed or bought. *)
