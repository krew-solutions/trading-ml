module Directive = Execution_management.Order_ticket.Values.Execution_directive
module Twap = Execution_management.Order_ticket.Values.Twap_params
module Vwap = Execution_management.Order_ticket.Values.Vwap_params
module Pov = Execution_management.Order_ticket.Values.Pov_params
module Iceberg = Execution_management.Order_ticket.Values.Iceberg_params
module Is = Execution_management.Order_ticket.Values.Implementation_shortfall_params

include Execution_directive_view_model_t
include Execution_directive_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

let twap_params_json (p : Twap.t) : string =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("n_slices", `Int p.n_slices);
         ("window_seconds", `Int p.window_seconds);
         ("start_at", `Intlit (Int64.to_string p.start_at));
       ])

let vwap_params_json (p : Vwap.t) : string =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("n_slices", `Int p.n_slices);
         ("window_seconds", `Int p.window_seconds);
         ("start_at", `Intlit (Int64.to_string p.start_at));
         ( "volume_profile",
           `List (List.map (fun w -> `Float w) p.volume_profile) );
       ])

let pov_params_json (p : Pov.t) : string =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("participation_rate", `Float p.participation_rate);
         ("timeframe", `String p.timeframe);
       ])

let iceberg_params_json (p : Iceberg.t) : string =
  Yojson.Safe.to_string
    (`Assoc [ ("visible_qty", `String (Decimal.to_string p.visible_qty)) ])

let is_params_json (p : Is.t) : string =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("n_slices", `Int p.n_slices);
         ("window_seconds", `Int p.window_seconds);
         ("start_at", `Intlit (Int64.to_string p.start_at));
         ("volatility", `Float p.volatility);
         ("risk_aversion", `Float p.risk_aversion);
         ("temp_impact_eta", `Float p.temp_impact_eta);
       ])

let of_domain (d : Directive.t) : t =
  match d with
  | Immediate -> { kind = "IMMEDIATE"; params = None }
  | Twap p -> { kind = "TWAP"; params = Some (twap_params_json p) }
  | Vwap p -> { kind = "VWAP"; params = Some (vwap_params_json p) }
  | Pov p -> { kind = "POV"; params = Some (pov_params_json p) }
  | Iceberg p -> { kind = "ICEBERG"; params = Some (iceberg_params_json p) }
  | Implementation_shortfall p ->
      { kind = "IMPLEMENTATION_SHORTFALL"; params = Some (is_params_json p) }
