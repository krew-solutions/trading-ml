open Core

type update = {
  trade_id : string;
  order_id : string;
  account_id : string;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  ts : int64;
}

let parse_side : Yojson.Safe.t -> Side.t = function
  | `String "SIDE_BUY" -> Side.Buy
  | `String "SIDE_SELL" -> Side.Sell
  | _ -> raise Exit

let parse_one (t : Yojson.Safe.t) : update option =
  let open Yojson.Safe.Util in
  try
    let trade_id = member "trade_id" t |> to_string in
    let order_id = member "order_id" t |> to_string in
    let account_id =
      match member "account_id" t with
      | `String s -> s
      | _ -> ""
    in
    let instrument = Instrument.of_qualified (member "symbol" t |> to_string) in
    let side = parse_side (member "side" t) in
    let quantity = Dto.decimal_field "size" t in
    let price = Dto.decimal_field "price" t in
    let ts =
      match member "timestamp" t with
      | `String s -> Datetime.Iso8601.parse s
      | `Int n -> Int64.of_int n
      | _ -> 0L
    in
    Some { trade_id; order_id; account_id; instrument; side; quantity; price; ts }
  with _ -> None

let parse (j : Yojson.Safe.t) : update list =
  let open Yojson.Safe.Util in
  let payload = Payload.unwrap (member "payload" j) in
  match member "trades" payload with
  | `List items -> List.filter_map parse_one items
  | _ -> []

let to_domain ~(placement_id : int) (tu : update) :
    Broker_domain.Remote_broker.Events.Trade_executed.t =
  {
    placement_id;
    trade_id = tu.trade_id;
    instrument = tu.instrument;
    side = tu.side;
    quantity = tu.quantity;
    price = tu.price;
    fee = Decimal.zero;
    ts = tu.ts;
  }
