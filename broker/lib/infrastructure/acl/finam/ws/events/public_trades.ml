open Core

type update = {
  side : Side.t option;
  quantity : Decimal.t;
  price : Decimal.t;
  ts : int64;
}

type t = { instrument : Instrument.t; trades : update list }

(* The single side-mapping point on the inbound path (ADR 0032).
   SIDE_BUY/SIDE_SELL are the venue's aggressor; SIDE_UNSPECIFIED (and
   any unexpected value) is [None] — auction crosses and negotiated
   trades with no initiator. *)
let parse_side : Yojson.Safe.t -> Side.t option = function
  | `String "SIDE_BUY" -> Some Side.Buy
  | `String "SIDE_SELL" -> Some Side.Sell
  | _ -> None

let parse_one (t : Yojson.Safe.t) : update option =
  let open Yojson.Safe.Util in
  try
    let side = parse_side (member "side" t) in
    let quantity = Dto.decimal_field "size" t in
    let price = Dto.decimal_field "price" t in
    let ts =
      match member "timestamp" t with
      | `String s -> Datetime.Iso8601.parse s
      | `Int n -> Int64.of_int n
      | _ -> 0L
    in
    Some { side; quantity; price; ts }
  with _ -> None

let parse (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let payload = Payload.unwrap (member "payload" j) in
  let instrument =
    match member "symbol" payload with
    | `String s -> Instrument.of_qualified s
    | _ -> (
        match member "subscription_key" j with
        | `String s -> Instrument.of_qualified s
        | _ -> invalid_arg "Finam INSTRUMENT_TRADES: envelope missing symbol")
  in
  let trades =
    match member "trades" payload with
    | `List items -> List.filter_map parse_one items
    | _ -> []
  in
  { instrument; trades }

let to_domain (t : t) :
    Broker_domain.Remote_broker.Events.Remote_public_trade_updated.t list =
  List.map
    (fun (u : update) ->
      {
        Broker_domain.Remote_broker.Events.Remote_public_trade_updated.instrument =
          t.instrument;
        side = u.side;
        quantity = u.quantity;
        price = u.price;
        ts = u.ts;
      })
    t.trades
