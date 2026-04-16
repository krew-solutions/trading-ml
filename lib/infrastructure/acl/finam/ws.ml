(** WebSocket subscription helpers for Finam Trade async-api.
    Defines the subscription protocol messages as pure DTOs and exposes a
    client over a generic [frame] sink/source. The Eio transport glue
    lives below. *)

open Core

type subscribe =
  | Sub_quotes of Instrument.t list
  | Sub_orderbook of Instrument.t list
  | Sub_bars of { instrument : Instrument.t; timeframe : Timeframe.t }
  | Sub_account of string

let subscribe_message id = function
  | Sub_quotes is ->
    `Assoc [
      "action", `String "subscribe";
      "channel", `String "quotes";
      "id", `String id;
      "symbols", `List (List.map (fun i ->
        `String (Rest.qualify_instrument i)) is);
    ]
  | Sub_orderbook is ->
    `Assoc [
      "action", `String "subscribe";
      "channel", `String "orderbook";
      "id", `String id;
      "symbols", `List (List.map (fun i ->
        `String (Rest.qualify_instrument i)) is);
    ]
  | Sub_bars { instrument; timeframe } ->
    `Assoc [
      "action", `String "subscribe";
      "channel", `String "bars";
      "id", `String id;
      "symbol", `String (Rest.qualify_instrument instrument);
      "timeframe", `String (Rest.timeframe_wire timeframe);
    ]
  | Sub_account account_id ->
    `Assoc [
      "action", `String "subscribe";
      "channel", `String "account";
      "id", `String id;
      "account_id", `String account_id;
    ]

type event =
  | Quote of { instrument : Instrument.t; bid : Decimal.t; ask : Decimal.t; ts : int64 }
  | Bar of { instrument : Instrument.t; candle : Candle.t }
  | Order_update of Yojson.Safe.t
  | Other of Yojson.Safe.t

let event_of_json (j : Yojson.Safe.t) : event =
  let open Yojson.Safe.Util in
  match member "channel" j with
  | `String "quotes" ->
    let instrument =
      Instrument.of_qualified (member "symbol" j |> to_string) in
    let bid = Dto.decimal_field "bid" j in
    let ask = Dto.decimal_field "ask" j in
    let ts = match member "timestamp" j with
      | `String s -> Dto.parse_iso8601 s
      | `Int n -> Int64.of_int n
      | _ -> 0L
    in
    Quote { instrument; bid; ask; ts }
  | `String "bars" ->
    let instrument =
      Instrument.of_qualified (member "symbol" j |> to_string) in
    let candle = Dto.candle_of_json (member "bar" j) in
    Bar { instrument; candle }
  | `String "orders" | `String "account" -> Order_update j
  | _ -> Other j
