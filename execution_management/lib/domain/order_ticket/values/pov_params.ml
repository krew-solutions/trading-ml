type t = { participation_rate : float; timeframe : string }

let make ~participation_rate ~timeframe =
  if participation_rate <= 0.0 || participation_rate > 1.0 then
    invalid_arg "Pov_params.make: participation_rate must be in (0, 1]";
  if timeframe = "" then
    invalid_arg "Pov_params.make: timeframe must be non-empty";
  { participation_rate; timeframe }
