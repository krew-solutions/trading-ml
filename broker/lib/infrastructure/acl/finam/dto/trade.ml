open Core

type t = {
  order_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  trade : Broker_domain.Order.Trade.t;
}

let of_json (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let str k =
    match member k j with
    | `String s -> s
    | _ -> ""
  in
  let dec k = try Wire.decimal_of_json (member k j) with _ -> Decimal.zero in
  let ts =
    match member "timestamp" j with
    | `String s -> Datetime.Iso8601.parse s
    | _ -> 0L
  in
  {
    order_id = str "order_id";
    instrument = Instrument.of_qualified (str "symbol");
    side = Wire.finam_side_of_wire (str "side");
    trade =
      {
        trade_id = str "trade_id";
        ts;
        quantity = dec "size";
        price = dec "price";
        fee = Decimal.zero;
      };
  }

let list_of_json (j : Yojson.Safe.t) : t list =
  let open Yojson.Safe.Util in
  match member "trades" j with
  | `List items -> List.map of_json items
  | _ -> []
