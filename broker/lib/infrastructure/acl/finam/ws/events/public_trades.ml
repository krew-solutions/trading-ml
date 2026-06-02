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

let update_to_domain ~instrument (u : update) :
    Broker_domain.Remote_broker.Events.Public_trade_printed.t =
  {
    Broker_domain.Remote_broker.Events.Public_trade_printed.instrument;
    side = u.side;
    quantity = u.quantity;
    price = u.price;
    ts = u.ts;
  }

let to_domain (t : t) : Broker_domain.Remote_broker.Events.Public_trade_printed.t list =
  List.map (update_to_domain ~instrument:t.instrument) t.trades

(* REST [/v1/instruments/{symbol}/trades/latest] parsing. The trade objects
   carry the same side / size / price / timestamp fields as the WS tape, so
   {!parse_one} is reused unchanged; each also carries a snake_case
   [trade_id] — Finam's monotonic per-instrument exchange sequence number —
   which the REST poller uses as a high-water dedup key. (The WS [update]
   has no id, and [ts] is unusable for dedup: many prints share one
   sub-second timestamp.) A trade whose id is absent or non-numeric parses
   with [None]; the lone [{"trade_id":"0"}] heartbeat stub has no
   price/size/side, so {!parse_one} already drops it. Response order is
   preserved (the caller sorts by id). *)
let parse_rest_latest (j : Yojson.Safe.t) : (int64 option * update) list =
  let open Yojson.Safe.Util in
  match member "trades" j with
  | `List items ->
      List.filter_map
        (fun it ->
          match parse_one it with
          | None -> None
          | Some u ->
              let id =
                match member "trade_id" it with
                | `String s -> Int64.of_string_opt s
                | `Int n -> Some (Int64.of_int n)
                | _ -> None
              in
              Some (id, u))
        items
  | _ -> []
