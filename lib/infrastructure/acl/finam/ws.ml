(** WebSocket subscription helpers for Finam Trade async-api.
    Defines the subscription protocol messages as pure DTOs and exposes a
    client over a generic [frame] sink/source. The Eio transport glue
    lives below. *)

open Core

type subscribe =
  | Sub_quotes of Symbol.t list
  | Sub_orderbook of Symbol.t list
  | Sub_bars of { symbol : Symbol.t; timeframe : Timeframe.t }
  | Sub_account of string

let subscribe_message id = function
  | Sub_quotes syms ->
    `Assoc [
      "action", `String "subscribe";
      "channel", `String "quotes";
      "id", `String id;
      "symbols", `List (List.map (fun s -> `String (Symbol.to_string s)) syms);
    ]
  | Sub_orderbook syms ->
    `Assoc [
      "action", `String "subscribe";
      "channel", `String "orderbook";
      "id", `String id;
      "symbols", `List (List.map (fun s -> `String (Symbol.to_string s)) syms);
    ]
  | Sub_bars { symbol; timeframe } ->
    `Assoc [
      "action", `String "subscribe";
      "channel", `String "bars";
      "id", `String id;
      "symbol", `String (Symbol.to_string symbol);
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
  | Quote of { symbol : Symbol.t; bid : Decimal.t; ask : Decimal.t; ts : int64 }
  | Bar of { symbol : Symbol.t; candle : Candle.t }
  | Order_update of Yojson.Safe.t
  | Other of Yojson.Safe.t

let event_of_json (j : Yojson.Safe.t) : event =
  let open Yojson.Safe.Util in
  match member "channel" j with
  | `String "quotes" ->
    let sym = Symbol.of_string (member "symbol" j |> to_string) in
    let bid = Dto.decimal_field "bid" j in
    let ask = Dto.decimal_field "ask" j in
    let ts = match member "timestamp" j with
      | `String s -> Dto.parse_iso8601 s
      | `Int n -> Int64.of_int n
      | _ -> 0L
    in
    Quote { symbol = sym; bid; ask; ts }
  | `String "bars" ->
    let sym = Symbol.of_string (member "symbol" j |> to_string) in
    let candle = Dto.candle_of_json (member "bar" j) in
    Bar { symbol = sym; candle }
  | `String "orders" | `String "account" -> Order_update j
  | _ -> Other j
