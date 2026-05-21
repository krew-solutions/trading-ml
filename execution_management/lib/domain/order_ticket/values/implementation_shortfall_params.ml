type t = {
  n_slices : int;
  window_seconds : int;
  start_at : int64;
  volatility : float;
  risk_aversion : float;
  temp_impact_eta : float;
}

let make ~n_slices ~window_seconds ~start_at ~volatility ~risk_aversion ~temp_impact_eta =
  if n_slices <= 0 then
    invalid_arg "Implementation_shortfall_params.make: n_slices must be > 0";
  if window_seconds <= 0 then
    invalid_arg "Implementation_shortfall_params.make: window_seconds must be > 0";
  if volatility < 0.0 then
    invalid_arg "Implementation_shortfall_params.make: volatility must be non-negative";
  if risk_aversion <= 0.0 then
    invalid_arg "Implementation_shortfall_params.make: risk_aversion must be positive";
  if temp_impact_eta <= 0.0 then
    invalid_arg "Implementation_shortfall_params.make: temp_impact_eta must be positive";
  { n_slices; window_seconds; start_at; volatility; risk_aversion; temp_impact_eta }
