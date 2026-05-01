(** Aggregate root: cash + map of open positions + outstanding
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

(*@ function dec_raw (d : Decimal.t) : integer *)
(** Local alias for [Decimal.t]'s scaled-integer projection. See the
    matching note in [core/candle.mli] — Gospel 0.3.1 doesn't carry
    [model] declarations across files, so each consumer restates it. *)

(** Re-exports of peer subdirs. [portfolio.ml] collapses the
    [portfolio/] namespace per dune's qualified-mode rule, so peer
    subdirectories are visible outside only through explicit
    publication here. *)

module Values : module type of Values
module Events : module type of Events
module Reservation : module type of Reservation

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
    command, log, surface to user). *)
type reservation_error =
  | Insufficient_cash of { required : Decimal.t; available : Decimal.t }
  | Insufficient_qty of { required : Decimal.t; available : Decimal.t }

val try_reserve :
  t ->
  id:int ->
  side:Core.Side.t ->
  instrument:Core.Instrument.t ->
  quantity:Decimal.t ->
  price:Decimal.t ->
  slippage_buffer:Decimal.t ->
  fee_rate:Decimal.t ->
  (t * Events.Amount_reserved.t, reservation_error) result
(** Checked reservation: verifies invariant (sufficient
    [available_cash] for Buy, [available_qty] for Sell), then
    delegates to {!reserve}. Returns new state together with the
    [Amount_reserved] event that reflects the transition, or a
    typed [reservation_error] if the invariant is violated. *)
(*@ r = try_reserve p ~id ~side ~instrument ~quantity ~price
                    ~slippage_buffer ~fee_rate
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
(** Settle part of reservation [id]. Shrinks the reservation by
    [actual_quantity] (its [reserved_cash] / [reserved_qty] scale
    down proportionally) and applies a {!fill} for that slice; the
    reservation stays open for the remaining amount. When the
    remaining quantity reaches zero the reservation is removed
    automatically (equivalent to {!commit_fill}).

    Raises [Not_found] when the id is absent. Raises
    [Invalid_argument] if [actual_quantity] exceeds the
    reservation's current [reserved_qty] (for sells) or if the
    caller tries to fill more than originally reserved (for buys). *)

val release : t -> id:int -> t
(** Drop reservation [id] with no other state change — used on
    cancel/reject. No-op if the reservation is absent. *)

val available_cash : t -> Decimal.t
(** [cash - Σ(r.reserved_cash for Buy reservations)]. What the
    strategy can still spend without overlapping with inflight
    orders. *)

val available_qty : t -> Core.Instrument.t -> Decimal.t
(** Signed position quantity after subtracting reservations for
    that instrument's pending sells (resp. buys for short covers).
    Returns [Decimal.zero] if there's no position and no
    reservation. *)

val equity : t -> (Core.Instrument.t -> Decimal.t option) -> Decimal.t
(** Mark-to-market equity = cash + Σ quantity·mark_price.
    Reservations are ignored — equity reflects only what's been
    actually cashed or bought. *)
