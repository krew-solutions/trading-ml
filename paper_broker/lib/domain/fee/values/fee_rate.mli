(** Fee rate the simulator charges on each fill: [fee = qty * price * rate].

    Invariants:
    - [rate >= 0] — fees never refund cash to the trader;
    - [rate < 1]  — a 100 % fee would imply the trader pays the
      full notional in fees alone, which is degenerate and almost
      certainly a configuration error. *)

type t = private Decimal.t

val of_decimal : Decimal.t -> t
(** Raises [Invalid_argument] when [d < 0] or [d >= 1]. *)

val to_decimal : t -> Decimal.t

val zero : t
(** [0]; the canonical "fee-free" setting for deterministic tests
    and the synthetic-data backtest. *)

val equal : t -> t -> bool
val compare : t -> t -> int
