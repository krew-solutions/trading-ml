open Core

(* Re-exports define the aggregate's public surface. dune's
   `(include_subdirs qualified)` collapses peer sub-directories into
   this file (matching the directory name), so they reach the
   outside only through these explicit aliases. *)
module Values = Values
module Events = Events
module Reservation = Reservation

(* Local shortcuts to keep the aggregate-root body terse. *)
module Position = Values.Position
module Amount_reserved = Events.Amount_reserved
module Reservation_released = Events.Reservation_released

type t = {
  cash : Decimal.t;
  positions : (Instrument.t * Position.t) list;
  realized_pnl : Decimal.t;
  reservations : Reservation.t list;
}

let empty ~cash = { cash; positions = []; realized_pnl = Decimal.zero; reservations = [] }

let position p instrument =
  List.find_opt (fun (i, _) -> Instrument.equal i instrument) p.positions
  |> Option.map snd

let set_position positions instrument (pos : Position.t) =
  let rest = List.filter (fun (i, _) -> not (Instrument.equal i instrument)) positions in
  if Decimal.is_zero pos.quantity then rest else (instrument, pos) :: rest

let fill (p : t) ~instrument ~side ~quantity ~price ~fee : t =
  if not (Decimal.is_positive quantity) then
    invalid_arg "Portfolio.fill: non-positive quantity";
  if Decimal.is_negative fee then invalid_arg "Portfolio.fill: negative fee";
  let signed_qty =
    match side with
    | Side.Buy -> quantity
    | Sell -> Decimal.neg quantity
  in
  let notional = Decimal.mul quantity price in
  let cash_delta =
    match side with
    | Buy -> Decimal.neg (Decimal.add notional fee)
    | Sell -> Decimal.sub notional fee
  in
  let cash' = Decimal.add p.cash cash_delta in
  let existing = position p instrument in
  let pos', realized =
    match existing with
    | None ->
        ( ({ instrument; quantity = signed_qty; avg_price = price } : Position.t),
          Decimal.zero )
    | Some (cur : Position.t) ->
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
          ({ cur with quantity = new_qty; avg_price = new_avg }, Decimal.zero)
        else
          (* opposing direction: realize PnL on the closed portion *)
          let abs_cur = Decimal.abs cur.quantity in
          let closed = Decimal.min abs_cur quantity in
          let pnl_per_unit =
            if cur_sign > 0 (* closing a long via sell *) then
              Decimal.sub price cur.avg_price
            else Decimal.sub cur.avg_price price
          in
          let realized = Decimal.mul closed pnl_per_unit in
          let new_qty = Decimal.add cur.quantity signed_qty in
          let new_avg =
            if Decimal.is_zero new_qty then Decimal.zero
            else if Decimal.compare quantity abs_cur > 0 then price
              (* flipped; the remainder opens a new position *)
            else cur.avg_price
          in
          ({ cur with quantity = new_qty; avg_price = new_avg }, realized)
  in
  {
    p with
    cash = cash';
    positions = set_position p.positions instrument pos';
    realized_pnl = Decimal.add p.realized_pnl realized;
  }

let reserve p ~id ~side ~instrument ~quantity ~price ~slippage_buffer ~fee_rate =
  let per_unit_cash =
    Reservation.per_unit_cash_of ~side ~price ~slippage_buffer ~fee_rate
  in
  let r : Reservation.t = { id; side; instrument; quantity; per_unit_cash } in
  { p with reservations = r :: p.reservations }

let find_reservation reservations id =
  List.partition (fun (r : Reservation.t) -> r.id = id) reservations

let release p ~id =
  let _matched, rest = find_reservation p.reservations id in
  { p with reservations = rest }

let commit_fill p ~id ~actual_quantity ~actual_price ~actual_fee =
  let matched, rest = find_reservation p.reservations id in
  match matched with
  | [] -> raise Not_found
  | (r : Reservation.t) :: _ ->
      let p' = { p with reservations = rest } in
      fill p' ~instrument:r.instrument ~side:r.side ~quantity:actual_quantity
        ~price:actual_price ~fee:actual_fee

let commit_partial_fill p ~id ~actual_quantity ~actual_price ~actual_fee =
  let matched, rest = find_reservation p.reservations id in
  match matched with
  | [] -> raise Not_found
  | (r : Reservation.t) :: _ ->
      if Decimal.compare actual_quantity r.quantity > 0 then
        invalid_arg
          "Portfolio.commit_partial_fill: actual_quantity exceeds remaining reserved \
           quantity";
      let new_remaining = Decimal.sub r.quantity actual_quantity in
      let reservations' =
        if Decimal.is_zero new_remaining then rest
        else { r with quantity = new_remaining } :: rest
      in
      let p' = { p with reservations = reservations' } in
      fill p' ~instrument:r.instrument ~side:r.side ~quantity:actual_quantity
        ~price:actual_price ~fee:actual_fee

let available_cash p =
  List.fold_left
    (fun acc (r : Reservation.t) ->
      match r.side with
      | Buy -> Decimal.sub acc (Reservation.reserved_cash r)
      | Sell -> acc)
    p.cash p.reservations

let available_qty p instrument =
  let base =
    match position p instrument with
    | Some (pos : Position.t) -> pos.quantity
    | None -> Decimal.zero
  in
  List.fold_left
    (fun acc (r : Reservation.t) ->
      if Instrument.equal r.instrument instrument then
        match r.side with
        | Sell -> Decimal.sub acc (Reservation.reserved_qty r)
        | Buy -> acc
      else acc)
    base p.reservations

let equity p mark =
  List.fold_left
    (fun acc (_, (pos : Position.t)) ->
      let px =
        match mark pos.instrument with
        | Some m -> m
        | None -> pos.avg_price
      in
      Decimal.add acc (Decimal.mul pos.quantity px))
    p.cash p.positions

type reservation_error =
  | Insufficient_cash of { required : Decimal.t; available : Decimal.t }
  | Insufficient_qty of { required : Decimal.t; available : Decimal.t }

let try_reserve p ~id ~side ~instrument ~quantity ~price ~slippage_buffer ~fee_rate =
  let per_unit_cash =
    Reservation.per_unit_cash_of ~side ~price ~slippage_buffer ~fee_rate
  in
  let required =
    match side with
    | Side.Buy -> Decimal.mul quantity per_unit_cash
    | Sell -> quantity
  in
  let available =
    match side with
    | Buy -> available_cash p
    | Sell -> available_qty p instrument
  in
  if Decimal.compare required available > 0 then
    let err =
      match side with
      | Buy -> Insufficient_cash { required; available }
      | Sell -> Insufficient_qty { required; available }
    in
    Error err
  else
    let p' =
      reserve p ~id ~side ~instrument ~quantity ~price ~slippage_buffer ~fee_rate
    in
    let event : Amount_reserved.t =
      {
        reservation_id = id;
        side;
        instrument;
        quantity;
        price;
        reserved_cash =
          (match side with
          | Buy -> required
          | Sell -> Decimal.zero);
      }
    in
    Ok (p', event)

type release_error = Reservation_not_found of int

let try_release p ~id =
  let matched, rest = find_reservation p.reservations id in
  match matched with
  | [] -> Error (Reservation_not_found id)
  | (r : Reservation.t) :: _ ->
      let p' = { p with reservations = rest } in
      let event : Reservation_released.t =
        { reservation_id = id; side = r.side; instrument = r.instrument }
      in
      Ok (p', event)
