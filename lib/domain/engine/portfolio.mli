(** Immutable portfolio: cash + map of open positions.
    Transitions are pure functions — the engine keeps the "current" portfolio
    as plain data. Gospel preconditions on [fill] document the safety
    obligations callers must satisfy. *)

type position = {
  symbol : Core.Symbol.t;
  quantity : Core.Decimal.t;   (** signed: positive = long, negative = short *)
  avg_price : Core.Decimal.t;  (** VWAP entry price *)
}

type t = private {
  cash : Core.Decimal.t;
  positions : (Core.Symbol.t * position) list;
  realized_pnl : Core.Decimal.t;
}

val empty : cash:Core.Decimal.t -> t
(*@ p = empty ~cash
    ensures p.positions = [] *)

val position : t -> Core.Symbol.t -> position option

val fill :
  t ->
  symbol:Core.Symbol.t ->
  side:Core.Side.t ->
  quantity:Core.Decimal.t ->
  price:Core.Decimal.t ->
  fee:Core.Decimal.t ->
  t
(** Apply a fill to the portfolio, updating cash, average price and realized
    PnL. Raises [Invalid_argument] on non-positive quantity. *)
(*@ r = fill t ~symbol ~side ~quantity ~price ~fee
    raises Invalid_argument _ -> true *)

val equity : t -> (Core.Symbol.t -> Core.Decimal.t option) -> Core.Decimal.t
(** Mark-to-market equity = cash + Σ quantity·mark_price.
    [mark] returns [None] for symbols we have no quote for — those positions
    are valued at the book's avg_price (conservative). *)
