type margin_terms = { margin_pct : Decimal.t; haircut : Decimal.t }
type t = Core.Instrument.t -> margin_terms

let constant ~margin_pct ~haircut : t = fun _ -> { margin_pct; haircut }
