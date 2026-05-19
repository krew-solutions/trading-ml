(** Which {!Sizing_policy.S} implementation a book uses to size
    its construction intents. Lives in [domain/common/] (not
    [domain/sizing_policy/]) so {!Risk_config} can hold it as
    a field without inverting the layering — sizing-policy
    modules can depend on this discriminator, not the other
    way round.

    Variant payloads carry the policy's [config] inline; the
    [config] types are deliberately re-stated here rather than
    re-exported from [domain/sizing_policy/] so the dependency
    direction stays one-way ([common] is below
    [sizing_policy]). Factory wiring fans this discriminator
    out into the matching {!Sizing_policy.S.size} call. *)

type t =
  | Equity_proportional
      (** No per-policy config; sizing is
          [book_equity × weight / mark] across every leg. *)
  | Volatility_target of {
      target_annual_vol : Decimal.t;
          (** Per-book annualised volatility budget, as a
              non-negative {!Decimal.t} (e.g. [0.10] for 10%).
              Validated at the application boundary. *)
    }

val equal : t -> t -> bool

val name : t -> string
(** Stable label for audit. ["equity_proportional"] or
    ["volatility_target"]. *)
