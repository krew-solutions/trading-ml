type t = { new_peak_equity : Decimal.t; occurred_at : int64 }

let make ~new_peak_equity ~occurred_at = { new_peak_equity; occurred_at }
