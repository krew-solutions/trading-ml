open Core

type position = {
  instrument : Instrument.t;
  quantity : Decimal.t;
  avg_price : Decimal.t;
}

type t = {
  cash : Decimal.t;
  positions : (Instrument.t * position) list;
  realized_pnl : Decimal.t;
}

let empty ~cash = { cash; positions = []; realized_pnl = Decimal.zero }

let position p instrument =
  List.find_opt (fun (i, _) -> Instrument.equal i instrument) p.positions
  |> Option.map snd

let set_position positions instrument pos =
  let rest =
    List.filter (fun (i, _) -> not (Instrument.equal i instrument)) positions
  in
  if Decimal.is_zero pos.quantity then rest
  else (instrument, pos) :: rest

let fill p ~instrument ~side ~quantity ~price ~fee =
  if not (Decimal.is_positive quantity) then
    invalid_arg "Portfolio.fill: non-positive quantity";
  if Decimal.is_negative fee then
    invalid_arg "Portfolio.fill: negative fee";
  let signed_qty = match side with
    | Side.Buy -> quantity
    | Sell -> Decimal.neg quantity
  in
  let notional = Decimal.mul quantity price in
  let cash_delta = match side with
    | Buy -> Decimal.neg (Decimal.add notional fee)
    | Sell -> Decimal.sub notional fee
  in
  let cash' = Decimal.add p.cash cash_delta in
  let existing = position p instrument in
  let pos', realized =
    match existing with
    | None ->
      { instrument; quantity = signed_qty; avg_price = price }, Decimal.zero
    | Some cur ->
      let cur_sign = Decimal.compare cur.quantity Decimal.zero in
      let new_sign = Decimal.compare signed_qty Decimal.zero in
      if cur_sign = 0 || cur_sign = new_sign then
        (* same direction: VWAP *)
        let new_qty = Decimal.add cur.quantity signed_qty in
        let total_notional =
          Decimal.add
            (Decimal.mul (Decimal.abs cur.quantity) cur.avg_price)
            (Decimal.mul quantity price)
        in
        let new_avg =
          if Decimal.is_zero new_qty then Decimal.zero
          else Decimal.div total_notional (Decimal.abs new_qty)
        in
        { cur with quantity = new_qty; avg_price = new_avg }, Decimal.zero
      else
        (* opposing direction: realize PnL on the closed portion *)
        let abs_cur = Decimal.abs cur.quantity in
        let closed = Decimal.min abs_cur quantity in
        let pnl_per_unit =
          if cur_sign > 0 (* closing a long via sell *)
          then Decimal.sub price cur.avg_price
          else Decimal.sub cur.avg_price price
        in
        let realized = Decimal.mul closed pnl_per_unit in
        let new_qty = Decimal.add cur.quantity signed_qty in
        let new_avg =
          if Decimal.is_zero new_qty then Decimal.zero
          else if Decimal.compare quantity abs_cur > 0
          then price  (* flipped; the remainder opens a new position *)
          else cur.avg_price
        in
        { cur with quantity = new_qty; avg_price = new_avg }, realized
  in
  {
    cash = cash';
    positions = set_position p.positions instrument pos';
    realized_pnl = Decimal.add p.realized_pnl realized;
  }

let equity p mark =
  List.fold_left
    (fun acc (_, pos) ->
       let px = match mark pos.instrument with
         | Some m -> m
         | None -> pos.avg_price
       in
       Decimal.add acc (Decimal.mul pos.quantity px))
    p.cash p.positions
