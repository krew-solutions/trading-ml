(** WebSocket subscription DTOs for BCS Trade API.

    Reference: [bcs-trade-go] client. Unlike Finam's multiplexed
    connection, BCS opens one WebSocket per [(classCode, ticker,
    timeFrame)] stream — the whole connection is implicitly tied to
    the subscription we send as the first message.

    Subscribe message (client → server):
    {[
      { "action":   "subscribe",
        "classCode": "TQBR",
        "ticker":    "SBER",
        "timeFrame": "M1"
      }
    ]}

    Event message (server → client) for the last-candle stream:
    {[
      { "type":      "<status>",
        "ticker":    "SBER",
        "classCode": "TQBR",
        "timeFrame": "M1",
        "bar": {
          "open": 320.5, "high": 321.0, "low": 319.8,
          "close": 320.7, "volume": 1234,
          "time":  "2026-04-16T10:00:00Z"
        }
      }
    ]}

    OHLCV fields arrive as JSON numbers here (BCS is not Decimal-safe
    on the wire), which differs from REST where we tolerate both. *)

open Core

(** Build the subscribe envelope for the last-candle stream. *)
let subscribe_last_candle_message ~class_code ~ticker ~timeframe : Yojson.Safe.t =
  `Assoc [
    "action",    `String "subscribe";
    "classCode", `String class_code;
    "ticker",    `String ticker;
    "timeFrame", `String (Rest.timeframe_wire timeframe);
  ]

(** Events surfaced to the bridge. We start minimal: a decoded candle
    tagged by its owning [(instrument, timeframe)], plus a catch-all
    for lifecycle / error frames we might see in logs. *)
type event =
  | Candle_ev of {
      instrument : Instrument.t;
      timeframe : Timeframe.t;
      candle : Candle.t;
    }
  | Other of Yojson.Safe.t

(** Map BCS's [timeFrame] strings (M1 … MN) back into our enum. Same
    table as [Rest.timeframe_wire] in reverse. *)
let timeframe_of_string : string -> Timeframe.t option = function
  | "M1" -> Some M1   | "M5" -> Some M5
  | "M15" -> Some M15 | "M30" -> Some M30
  | "H1" -> Some H1   | "H4" -> Some H4
  | "D"  -> Some D1
  | "W"  -> Some W1
  | "MN" -> Some MN1
  | _ -> None

let candle_of_bar_json (j : Yojson.Safe.t) : Candle.t =
  let open Yojson.Safe.Util in
  let ts = match member "time" j with
    | `String s -> Candle_json.parse_iso8601 s
    | `Int n -> Int64.of_int n
    | `Intlit s -> Int64.of_string s
    | _ -> 0L
  in
  let dec k =
    match member k j with
    | `Float f -> Decimal.of_float f
    | `Int n -> Decimal.of_int n
    | `String s -> Decimal.of_string s
    | `Intlit s -> Decimal.of_string s
    | _ -> Decimal.zero
  in
  Candle.make ~ts
    ~open_:(dec "open") ~high:(dec "high")
    ~low:(dec "low") ~close:(dec "close")
    ~volume:(dec "volume")

let event_of_json (j : Yojson.Safe.t) : event =
  let open Yojson.Safe.Util in
  match member "bar" j, member "ticker" j, member "classCode" j with
  | (`Assoc _ as bar), `String ticker, `String class_code ->
    (* BCS WS format: the payload carries classCode, ticker, timeFrame
       and an embedded bar. Recover the MIC from the board — BCS is
       MOEX-only in our current config, so [MISX] is a safe default;
       future venues would require a class_code → mic map. *)
    let instrument = Instrument.make
      ~ticker:(Ticker.of_string ticker)
      ~venue:(Mic.of_string "MISX")
      ~board:(Board.of_string class_code)
      ()
    in
    let timeframe =
      match member "timeFrame" j with
      | `String s ->
        (match timeframe_of_string s with
         | Some tf -> tf
         | None -> Timeframe.H1 (* unexpected — pick a safe default *))
      | _ -> Timeframe.H1
    in
    let candle = candle_of_bar_json bar in
    Candle_ev { instrument; timeframe; candle }
  | _ -> Other j
