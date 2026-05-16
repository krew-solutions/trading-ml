(** Execution directive — HOW to execute the trader intent.

    Closed variant: one constructor per strategy kind. Per-strategy
    parameters travel inside the constructor. In PR1 only
    [Immediate] is populated; subsequent PRs add Twap, Vwap, Pov,
    Iceberg, Implementation_shortfall under the same variant.

    The directive originates at portfolio_management as part of the
    trader intent and flows through pre_trade_risk unchanged
    (PTR is an approver, not an enricher). Execution_management's
    ACL reads it from the wire; absent → fallback to internal
    [Execution_policy.default] (today: [Immediate]). *)

type t = Immediate
