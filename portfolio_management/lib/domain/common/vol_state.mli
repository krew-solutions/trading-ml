(** Rolling-window estimator of annualised fractional
    {!Volatility.t} from a stream of close prices.

    Pure VO: no I/O, no side effects, no events. Configuration
    travels in the value itself (window length, annualisation
    factor); each {!update} call yields the new state, and
    {!current} projects the latest computed estimate when the
    window has filled.

    Standard formula:
      log_return_t = ln(close_t / close_{t-1})
      σ̂ = stdev(log_returns) over the last [window] returns
      annualised_vol = σ̂ × sqrt(annualisation_factor)

    The annualisation_factor scales single-period stdev to a
    yearly figure: ~252 for daily bars, ~252×6.5 for hourly
    intraday on US equities, etc. The estimator is agnostic to
    the unit — the caller is responsible for matching the
    factor to the bar timeframe.

    Numerical: log-returns use float arithmetic (log/sqrt are
    not in Decimal). The result is materialised as
    {!Volatility.t} (Decimal-backed) so downstream sizing math
    stays in fixed-point. The float→Decimal boundary at
    [current] is the only floating step in the path. *)

type t

val init : window:int -> annualisation_factor:float -> t
(** [init ~window ~annualisation_factor] creates an empty
    estimator. Raises [Invalid_argument] when [window < 3]
    (Bessel-corrected sample stdev needs at least two returns,
    so three closes) or when [annualisation_factor <= 0]. *)

val update : t -> close:Decimal.t -> t
(** Append a new close to the rolling window. Non-positive
    closes are rejected (the log-return would be undefined);
    [Invalid_argument] is raised at the boundary because a
    non-positive price is a producer-side bug.

    The first close fills slot 0; the second yields one
    log-return; the [window]-th yields ([window] − 1) returns
    and {!current} starts to project a non-[None] estimate. *)

val current : t -> Volatility.t option
(** [Some] once the window has accumulated at least
    [window] closes (so at least [window − 1] returns are
    available); [None] before that. *)

val sample_count : t -> int
(** Number of close prices accumulated so far; capped at
    [window]. Exposed for diagnostic / test introspection. *)
