(** Read-side projection of {!Pre_trade_risk.Risk_view.Values.Position_snapshot.t}.
    Decimal fields serialised as strings for bit-exact round-trip
    (project rule, see ADR 0007). *)

type t = { instrument : Instrument_view_model.t; quantity : string; avg_price : string }
[@@deriving yojson]

type domain = Pre_trade_risk.Risk_view.Values.Position_snapshot.t

val of_domain : domain -> t
