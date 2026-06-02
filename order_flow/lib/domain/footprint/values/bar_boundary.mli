(** Bar boundary policy — what ends one footprint bar and starts the
    next.

    Two boundaries are implemented: [Time tf] (fixed wall-clock period,
    the bring-up default — ADR 0032 §5) and [Volume cap] (a bar fills to
    a constant traded volume, de Prado's information-driven bar). They
    differ structurally, not by parameter alone — see {!admits_time_close}
    — so the polymorphic seam lives in the type, not in a numeric field.
    [Tick] is the next planned case and drops in the same way.

    Membership differs by boundary, and that difference is load-bearing:

    - A [Time] bar's membership is a pure function of a print's timestamp
      ({!bucket_start}); it is stateless, which is exactly what the
      fold-order independence argument exploits — reordering prints does
      not change which bar each lands in.
    - A [Volume] bar's membership depends on the running total of the
      open bar (has it reached [cap]?), so it is decided by the aggregate
      (which holds that total), not here. Its partition is therefore
      sequence-dependent: which print first fills the bar is a function
      of arrival order. The cluster algebra within any fixed bar stays
      order-independent ([Cluster.add] commutes); the partition does
      not. *)

type t = Time of Core.Timeframe.t | Volume of Decimal.t

val admits_time_close : t -> bool
(** Whether a bar under this boundary can close from the passage of
    time alone, with no further prints. A [Time] bar must close at its
    period edge even in a silent market, so [true]. A [Volume] bar only
    closes on the print that reaches [cap], so [false]. The live
    application layer uses this to drive a clock-triggered flush; in
    backtest a [Time] bar closes lazily on the first print of the next
    bucket, and a [Volume] bar on the print that fills it. *)
(*@ r = admits_time_close b
    ensures match b with Time _ -> r = true | Volume _ -> r = false *)

val period_seconds : t -> int
(** Bar length in whole seconds for a [Time] boundary
    ([Core.Timeframe.to_seconds]); always positive. Partial: raises
    [Invalid_argument] on a [Volume] boundary, which has no time period.
    The aggregate never calls it for [Volume] — it matches the variant
    first. *)
(*@ r = period_seconds b
    requires match b with Time _ -> true | Volume _ -> false
    ensures r > 0 *)

val to_token : t -> string
(** Canonical wire token for a boundary — the single spelling shared by
    the footprint integration event's [timeframe] field and the
    [Watch_footprints_command] boundary field, so the demand command and
    the published fact name the same boundary identically. [Time tf] is
    its timeframe code ([M1] … [MN1]); [Volume cap] is [VOL:<cap>] with
    [cap] rendered by {!Decimal.to_string}. A string codec, outside the
    Why3 arithmetic model (which covers only [Time] bucketing). *)

val of_token : string -> t
(** Inverse of {!to_token}: ["M5"] → [Time M5], ["VOL:1000"] →
    [Volume 1000]. Partial — raises [Invalid_argument] on a token that is
    neither a known timeframe nor a well-formed [VOL:<decimal>]. Round-trips
    with {!to_token}: [of_token (to_token b) = b]. *)

val bucket_start : t -> ts:int64 -> int64
(** Canonical open timestamp of the bar containing [ts]. For [Time tf],
    [ts] floored to the period: [ts - (ts mod period)]. Two prints
    share a [Time] bar iff their [bucket_start] coincide; a strictly
    greater [bucket_start] means the print opens a later bar, a smaller
    one means it is late for an already-passed bucket. Requires
    [ts >= 0] (unix epoch). Partial: raises [Invalid_argument] on a
    [Volume] boundary, whose membership is not time-bucketed — the
    aggregate decides [Volume] placement from the running total instead
    and never calls this. *)
(*@ r = bucket_start b ~ts
    requires match b with Time _ -> true | Volume _ -> false
    requires ts >= 0L *)
