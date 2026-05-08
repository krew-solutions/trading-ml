type outcome = Approve of Decimal.t | Reject of string

let mark_or_avg
    ~(mark : Core.Instrument.t -> Decimal.t option)
    (p : Risk_view.Values.Position_snapshot.t) : Decimal.t =
  match mark (Risk_view.Values.Position_snapshot.instrument p) with
  | Some m -> m
  | None -> Risk_view.Values.Position_snapshot.avg_price p

let equity_marked_to_market
    ~(view : Risk_view.t)
    ~(mark : Core.Instrument.t -> Decimal.t option) : Decimal.t =
  List.fold_left
    (fun acc p ->
      let m = mark_or_avg ~mark p in
      let qty = Risk_view.Values.Position_snapshot.quantity p in
      Decimal.add acc (Decimal.mul qty m))
    (Risk_view.cash view) (Risk_view.positions view)

let gross_exposure ~(view : Risk_view.t) ~(mark : Core.Instrument.t -> Decimal.t option) :
    Decimal.t =
  List.fold_left
    (fun acc p ->
      let m = mark_or_avg ~mark p in
      let qty = Risk_view.Values.Position_snapshot.quantity p in
      Decimal.add acc (Decimal.abs (Decimal.mul qty m)))
    Decimal.zero (Risk_view.positions view)

let assess
    ~(view : Risk_view.t)
    ~(limits : Risk_limits.t)
    ~(side : Core.Side.t)
    ~instrument:(_instrument : Core.Instrument.t)
    ~(quantity : Decimal.t)
    ~(price : Decimal.t)
    ~(mark : Core.Instrument.t -> Decimal.t option) : outcome =
  if Decimal.is_zero quantity then Reject "zero quantity"
  else if Decimal.is_zero price then Reject "zero price"
  else
    let notional = Decimal.mul quantity price in
    let cash = Risk_view.cash view in
    let cash_after =
      match side with
      | Core.Side.Buy -> Decimal.sub cash notional
      | Core.Side.Sell -> Decimal.add cash notional
    in
    if Decimal.compare cash_after (Risk_limits.min_cash_buffer limits) < 0 then
      Reject "would breach min_cash_buffer"
    else
      let gross = gross_exposure ~view ~mark in
      let gross' = Decimal.add gross notional in
      if Decimal.compare gross' (Risk_limits.max_gross_exposure limits) > 0 then
        Reject "max_gross_exposure"
      else
        let equity = equity_marked_to_market ~view ~mark in
        if Decimal.is_positive equity then
          let lev = Decimal.to_float gross' /. Decimal.to_float equity in
          if lev > Risk_limits.max_leverage limits then Reject "max_leverage"
          else Approve quantity
        else Reject "non-positive equity"
