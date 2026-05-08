type t = {
  peak_equity : Decimal.t;
  current_equity : Decimal.t;
  drawdown : float;
  occurred_at : int64;
}

let make ~peak_equity ~current_equity ~drawdown ~occurred_at =
  { peak_equity; current_equity; drawdown; occurred_at }
