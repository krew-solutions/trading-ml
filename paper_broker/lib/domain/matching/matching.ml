module Values = Values
open Core

let price_if_filled
    ~(kind : Order.Values.Order_kind.t)
    ~(side : Side.t)
    ~(candle : Candle.t) : Decimal.t option =
  let open_ = candle.open_ in
  let low = candle.low in
  let high = candle.high in
  match (kind, side) with
  | Market, _ -> Some open_
  | Limit lim, Buy ->
      if Decimal.compare open_ lim <= 0 then Some open_
      else if Decimal.compare low lim <= 0 then Some lim
      else None
  | Limit lim, Sell ->
      if Decimal.compare open_ lim >= 0 then Some open_
      else if Decimal.compare high lim >= 0 then Some lim
      else None
  | Stop stop, Buy ->
      if Decimal.compare open_ stop >= 0 then Some open_
      else if Decimal.compare high stop >= 0 then Some stop
      else None
  | Stop stop, Sell ->
      if Decimal.compare open_ stop <= 0 then Some open_
      else if Decimal.compare low stop <= 0 then Some stop
      else None
  | Stop_limit _, _ -> None

let fillable_qty
    ~(remaining : Decimal.t)
    ~(volume : Decimal.t)
    ~(participation_rate : Values.Participation_rate.t option) : Decimal.t =
  match participation_rate with
  | None -> remaining
  | Some rate ->
      let cap = Decimal.mul volume (Values.Participation_rate.to_decimal rate) in
      if Decimal.compare cap remaining < 0 then cap else remaining
