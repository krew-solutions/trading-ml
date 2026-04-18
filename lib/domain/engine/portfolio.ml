open Core

type position = {
  instrument : Instrument.t;
  quantity : Decimal.t;
  avg_price : Decimal.t;
}

type reservation = {
  id : int;
  side : Side.t;
  instrument : Instrument.t;
  reserved_cash : Decimal.t;
  reserved_qty : Decimal.t;
}

type t = {
  cash : Decimal.t;
  positions : (Instrument.t * position) list;
  realized_pnl : Decimal.t;
  reservations : reservation list;
}

let empty ~cash = {
  cash; positions = []; realized_pnl = Decimal.zero;
  reservations = [];
}

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
    p with
    cash = cash';
    positions = set_position p.positions instrument pos';
    realized_pnl = Decimal.add p.realized_pnl realized;
  }

(** Compute the cash-impact of a future fill for reservation
    purposes. For Buy: notional × (1 + slip) plus fee estimate;
    for Sell: zero (sells free cash). *)
let reserved_cash_of ~side ~quantity ~price ~slippage_buffer ~fee_rate =
  match side with
  | Side.Sell -> Decimal.zero
  | Buy ->
    let slip_mult = Decimal.of_float (1.0 +. slippage_buffer) in
    let notional_with_slip =
      Decimal.mul (Decimal.mul quantity price) slip_mult in
    let fee_est =
      Decimal.mul (Decimal.mul quantity price) (Decimal.of_float fee_rate) in
    Decimal.add notional_with_slip fee_est

(** Qty reserved per reservation: for Sell we lock the shares being
    exited; Buy doesn't lock position qty. *)
let reserved_qty_of ~side ~quantity =
  match side with
  | Side.Buy -> Decimal.zero
  | Sell -> quantity

let reserve p ~id ~side ~instrument ~quantity ~price
    ~slippage_buffer ~fee_rate =
  let reserved_cash = reserved_cash_of ~side ~quantity ~price
    ~slippage_buffer ~fee_rate in
  let reserved_qty = reserved_qty_of ~side ~quantity in
  let r = { id; side; instrument; reserved_cash; reserved_qty } in
  { p with reservations = r :: p.reservations }

let find_reservation reservations id =
  List.partition (fun r -> r.id = id) reservations

let release p ~id =
  let _matched, rest = find_reservation p.reservations id in
  { p with reservations = rest }

let commit_fill p ~id ~actual_quantity ~actual_price ~actual_fee =
  let matched, rest = find_reservation p.reservations id in
  match matched with
  | [] -> raise Not_found
  | r :: _ ->
    let p' = { p with reservations = rest } in
    fill p' ~instrument:r.instrument ~side:r.side
      ~quantity:actual_quantity ~price:actual_price ~fee:actual_fee

let available_cash p =
  List.fold_left (fun acc r ->
    match r.side with
    | Buy -> Decimal.sub acc r.reserved_cash
    | Sell -> acc)
    p.cash p.reservations

let available_qty p instrument =
  let base = match position p instrument with
    | Some pos -> pos.quantity
    | None -> Decimal.zero
  in
  List.fold_left (fun acc r ->
    if Instrument.equal r.instrument instrument then
      match r.side with
      | Sell -> Decimal.sub acc r.reserved_qty
      | Buy -> acc
    else acc)
    base p.reservations

let equity p mark =
  List.fold_left
    (fun acc (_, (pos : position)) ->
       let px = match mark pos.instrument with
         | Some m -> m
         | None -> pos.avg_price
       in
       Decimal.add acc (Decimal.mul pos.quantity px))
    p.cash p.positions
