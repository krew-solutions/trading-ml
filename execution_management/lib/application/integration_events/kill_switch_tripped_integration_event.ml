type t = {
  peak_equity : string;
  current_equity : string;
  drawdown : float;
  occurred_at : string;
}
[@@deriving yojson]
