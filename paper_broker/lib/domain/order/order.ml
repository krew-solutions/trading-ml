module Values = Values
module Events = Events

type t = {
  id : string;
  placement_id : Values.Placement_id.t;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  kind : Values.Order_kind.t;
  tif : Values.Time_in_force.t;
  status : Values.Order_status.t;
  created_ts : int64;
  placed_after_ts : int64;
}

let remaining (t : t) = Decimal.sub t.quantity t.filled
let is_terminal (t : t) = Values.Order_status.is_terminal t.status

let make
    ~id
    ~placement_id
    ~instrument
    ~side
    ~quantity
    ~kind
    ~tif
    ~created_ts
    ~placed_after_ts =
  if not (Decimal.is_positive quantity) then
    invalid_arg
      (Printf.sprintf "Order.make: quantity %s — must be > 0" (Decimal.to_string quantity));
  if Int64.compare created_ts 0L < 0 then invalid_arg "Order.make: created_ts < 0";
  if Int64.compare placed_after_ts 0L < 0 then
    invalid_arg "Order.make: placed_after_ts < 0";
  let order =
    {
      id;
      placement_id;
      instrument;
      side;
      quantity;
      filled = Decimal.zero;
      kind;
      tif;
      status = Values.Order_status.New;
      created_ts;
      placed_after_ts;
    }
  in
  let event : Events.Order_accepted.t =
    { id; placement_id; instrument; side; quantity; created_ts }
  in
  (order, event)

type commit_fill_error =
  | Order_already_terminal of Values.Order_status.t
  | Overfill of { remaining : Decimal.t; attempted : Decimal.t }
  | Non_positive_fill_quantity of Decimal.t
  | Negative_fee of Decimal.t

let commit_fill t ~trade_id ~fill_quantity ~fill_price ~fee ~fill_ts =
  if is_terminal t then Error (Order_already_terminal t.status)
  else if not (Decimal.is_positive fill_quantity) then
    Error (Non_positive_fill_quantity fill_quantity)
  else if Decimal.is_negative fee then Error (Negative_fee fee)
  else
    let rem = remaining t in
    if Decimal.compare fill_quantity rem > 0 then
      Error (Overfill { remaining = rem; attempted = fill_quantity })
    else
      let new_total_filled = Decimal.add t.filled fill_quantity in
      let new_status : Values.Order_status.t =
        if Decimal.equal new_total_filled t.quantity then Filled else Partially_filled
      in
      let t' = { t with filled = new_total_filled; status = new_status } in
      let event : Events.Trade_executed.t =
        {
          id = t.id;
          placement_id = t.placement_id;
          trade_id;
          instrument = t.instrument;
          side = t.side;
          quantity = fill_quantity;
          price = fill_price;
          fee;
          ts = fill_ts;
        }
      in
      Ok (t', event)

type cancel_error = Order_already_terminal of Values.Order_status.t

let cancel t ~cancelled_ts =
  if is_terminal t then Error (Order_already_terminal t.status)
  else
    let t' = { t with status = Cancelled } in
    let event : Events.Order_cancelled.t =
      {
        id = t.id;
        placement_id = t.placement_id;
        instrument = t.instrument;
        cancelled_ts;
      }
    in
    Ok (t', event)
