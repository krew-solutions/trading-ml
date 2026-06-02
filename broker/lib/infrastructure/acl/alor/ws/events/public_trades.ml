open Core

type t = Broker_domain.Remote_broker.Events.Public_trade_printed.t

(* The single side-mapping point for Alor (ADR 0032). AllTrades reports
   the aggressor as lowercase "buy"/"sell"; anything else is [None].
   Unlike [Dto.Wire.side_of_wire] (which defaults unknown to Buy, fine
   for our own fills) the public tape must not fabricate a side. *)
let parse_side = function
  | "buy" | "Buy" | "BUY" -> Some Side.Buy
  | "sell" | "Sell" | "SELL" -> Some Side.Sell
  | _ -> None

(* The instrument is the one the caller subscribed for (the bridge tracks
   it per guid), NOT one reconstructed from the frame: Alor's "Simple"
   AllTrades frame omits [exchange], so [Dto.Wire.instrument_of_json] would
   default the venue to the XXXX placeholder. Mirrors the bars path, which
   already stamps the subscribed (instrument, timeframe). *)
let parse ~instrument (data : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let str k =
    match member k data with
    | `String s -> s
    | _ -> ""
  in
  let dec k =
    try Acl_common.Decimal_wire.of_yojson_flex (member k data) with _ -> Decimal.zero
  in
  let ts =
    match member "timestamp" data with
    | `Int n -> Int64.of_int n
    | `Intlit s -> ( try Int64.of_string s with _ -> 0L)
    | _ -> (
        match member "time" data with
        | `String s -> Datetime.Iso8601.parse s
        | `Int n -> Int64.of_int n
        | _ -> 0L)
  in
  {
    Broker_domain.Remote_broker.Events.Public_trade_printed.instrument;
    side = parse_side (str "side");
    quantity = dec "qty";
    price = dec "price";
    ts;
  }
