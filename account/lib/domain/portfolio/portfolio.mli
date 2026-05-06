(** Aggregate root: cash + map of open positions + outstanding
    reservations.

    Reservations are pending buy/sell intents whose cash/qty impact
    has been *committed to availability* but not yet *applied to
    cash/positions*. They exist because live brokers acknowledge
    orders and fill them at different times — between "we sent the
    order" and "broker reports the fill", the funds (or qty) must
    be treated as unavailable so the strategy cannot collectively
    overcommit.

    A reservation can carry a {b cover} part (closes the
    opposite-side existing position) and an {b open} part (opens
    or grows a same-side position). Cover does not block cash;
    open blocks margin via [per_unit_collateral]. See
    [reservation/reservation.mli] for the per-Entity invariants.

    Backtest doesn't have the broker-RTT latency gap, so it does
    [reserve → commit_fill] atomically per tick; Live does
    [reserve → broker RTT → commit_fill] with reconciliation.
    Same API, different timing.

    Gospel preconditions on the transition operations document
    the safety obligations callers must satisfy. *)

(*@ function dec_raw (d : Decimal.t) : integer *)

(** Re-exports of peer subdirs. [portfolio.ml] collapses the
    [portfolio/] namespace per dune's qualified-mode rule, so peer
    subdirectories are visible outside only through explicit
    publication here. *)

module Values : module type of Values
module Events : module type of Events
module Reservation : module type of Reservation
module Margin_policy : module type of Margin_policy

type t = private {
  cash : Decimal.t;
  positions : (Core.Instrument.t * Values.Position.t) list;
  realized_pnl : Decimal.t;
  reservations : Reservation.t list;
}

val empty : cash:Decimal.t -> t
(*@ p = empty ~cash
    ensures p.cash = cash
    ensures p.positions = []
    ensures p.reservations = []
    ensures dec_raw p.realized_pnl = 0 *)

(** Reasons why the aggregate refuses to reserve — business-rule
    failures, not programming errors. Surfaces at the boundary
    of the first-stage handler so callers can react (reject the
    command, log, surface to user).

    [Insufficient_margin] fires on the Sell-open path when the
    open portion's collateral would exceed [buying_power]; for a
    Buy that is wholly cash-bounded, [Insufficient_cash] fires
    instead. *)
type reservation_error =
  | Insufficient_cash of { required : Decimal.t; available : Decimal.t }
  | Insufficient_margin of { required : Decimal.t; available : Decimal.t }

val try_reserve :
  t ->
  id:int ->
  side:Core.Side.t ->
  instrument:Core.Instrument.t ->
  quantity:Decimal.t ->
  price:Decimal.t ->
  slippage_buffer:Decimal.t ->
  fee_rate:Decimal.t ->
  margin_policy:Margin_policy.t ->
  mark:(Core.Instrument.t -> Decimal.t option) ->
  (t * Events.Amount_reserved.t, reservation_error) result
(** Checked reservation. For Buy: bounded by [available_cash]; the
    margin model does not extend Buy a haircut-based buying power
    in this round. For Sell: splits into a cover portion (bounded
    by the existing long quantity, no cash blocked) and an open
    portion (no qty bound, collateral
    [open_qty × price × margin_pct] checked against
    [buying_power]). Returns the new state plus the
    [Amount_reserved] event reflecting the transition, or a typed
    [reservation_error] on rejection. *)
(*@ r = try_reserve p ~id ~side ~instrument ~quantity ~price
                    ~slippage_buffer ~fee_rate ~margin_policy ~mark
    ensures match r with
            | Ok (p', ev) ->
                ev.reservation_id = id
                /\ ev.side = side
                /\ ev.instrument = instrument
                /\ ev.quantity = quantity
                /\ ev.price = price
                /\ List.length p'.reservations
                     = List.length p.reservations + 1
            | Error _ -> true *)

type release_error = Reservation_not_found of int

val try_release : t -> id:int -> (t * Events.Reservation_released.t, release_error) result
(** Releases a reservation by id, returning new state and the
    event. Returns [Reservation_not_found] if no reservation
    with that id exists — callers that want idempotent behaviour
    can treat this as a no-op. *)
(*@ r = try_release p ~id
    ensures match r with
            | Ok (p', ev) ->
                ev.reservation_id = id
                /\ List.length p'.reservations
                     = List.length p.reservations - 1
            | Error (Reservation_not_found n) ->
                n = id
                /\ List.for_all (fun res -> res.id <> id) p.reservations *)

val position : t -> Core.Instrument.t -> Values.Position.t option

val fill :
  t ->
  instrument:Core.Instrument.t ->
  side:Core.Side.t ->
  quantity:Decimal.t ->
  price:Decimal.t ->
  fee:Decimal.t ->
  t
(** Direct fill without reservation — used by the synthetic-fill
    path (Backtest, Paper) for code that doesn't route through the
    reserve/commit cycle. For the reserved path, use
    [reserve] + [commit_fill].

    Raises [Invalid_argument] on non-positive quantity. *)
(*@ r = fill t ~instrument ~side ~quantity ~price ~fee
    raises Invalid_argument _ -> dec_raw quantity <= 0 *)

val reserve :
  t ->
  id:int ->
  side:Core.Side.t ->
  instrument:Core.Instrument.t ->
  quantity:Decimal.t ->
  price:Decimal.t ->
  slippage_buffer:Decimal.t ->
  fee_rate:Decimal.t ->
  margin_policy:Margin_policy.t ->
  t
(** Unchecked reservation: builds the cover/open split from current
    position and pushes the reservation onto the list without
    verifying the buying-power constraint. The caller is responsible
    for the business-rule check; prefer [try_reserve] in the
    workflow path.

    For [Buy]: reserves [qty × (price × (1 + slippage_buffer) +
    price × fee_rate)] cash; [cash] is unchanged but
    [available_cash] drops.

    For [Sell]: cover_qty closes the long up to [position_qty]; the
    open_qty remainder reserves
    [open_qty × price × margin_pct] collateral. *)

val commit_fill :
  t ->
  id:int ->
  actual_quantity:Decimal.t ->
  actual_price:Decimal.t ->
  actual_fee:Decimal.t ->
  t
(** Settle reservation [id] fully with actual broker numbers. Removes
    the reservation and applies a real {!fill} using the actual
    values. If the reservation is absent (already committed or never
    existed), raises [Not_found]. *)

val commit_partial_fill :
  t ->
  id:int ->
  actual_quantity:Decimal.t ->
  actual_price:Decimal.t ->
  actual_fee:Decimal.t ->
  t
(** Settle part of reservation [id]. Cover-first attribution:
    [actual_quantity] depletes [cover_qty] before [open_qty], so the
    open portion's collateral block stays in place as long as
    possible. The reservation is removed automatically when both
    [cover_qty] and [open_qty] reach zero (equivalent to
    {!commit_fill}).

    Raises [Not_found] when the id is absent. Raises
    [Invalid_argument] if [actual_quantity] exceeds the
    reservation's combined remaining quantity. *)

val release : t -> id:int -> t
(** Drop reservation [id] with no other state change — used on
    cancel/reject. No-op if the reservation is absent. *)

val available_cash : t -> Decimal.t
(** [cash − Σ reserved_cash r for all r in reservations]. What
    the strategy can still spend without overlapping with inflight
    cash-blocking reservations (Buy reservations and Sell-open
    portions). *)

val available_qty : t -> Core.Instrument.t -> Decimal.t
(** Signed position quantity after subtracting cover_qty for that
    instrument's pending sells. The open portion of a Sell does
    not consume position quantity (a short can grow without
    consuming long-side qty), so it is not counted here. *)

val buying_power :
  t ->
  margin_policy:Margin_policy.t ->
  mark:(Core.Instrument.t -> Decimal.t option) ->
  Decimal.t
(** [available_cash + Σ |position_qty| × mark × haircut]. The cap
    against which the open portion of a Sell is checked. When [mark]
    returns [None], the position's [avg_price] is used as fallback. *)

val equity : t -> (Core.Instrument.t -> Decimal.t option) -> Decimal.t
(** Mark-to-market equity = cash + Σ quantity·mark_price.
    Reservations are ignored — equity reflects only what's been
    actually cashed or bought. *)
