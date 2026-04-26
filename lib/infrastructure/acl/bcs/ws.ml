(** WebSocket subscription DTOs for BCS Trade API — multiplexed
    [/market-data/ws] endpoint.

    Reference: saved copy of the official docs page
    "Последняя-свеча-БКС-Торговое-API.html" (section «Описание протокола»).

    Subscribe / unsubscribe envelope (client → server):
    {[
      { "subscribeType": 0,        (* 0 — subscribe, 1 — unsubscribe *)
        "dataType":      1,        (* 1 — candles *)
        "timeFrame":     "M1",     (* M1 M5 M15 M30 H1 H4 D W MN *)
        "instruments":  [ { "classCode": "TQBR", "ticker": "SBER" } ] }
    ]}

    Server responses carry a [responseType] discriminator:

    {[
      (* Subscription ack *)
      { "responseType": "CandleStickSuccess",
        "subscribeType": 0,
        "ticker": "SBER", "classCode": "TQBR", "timeFrame": "M1",
        "dateTime": "2024-11-10T10:30:00.000Z" }

      (* Candle tick (OHLCV flat, no nested "bar" object) *)
      { "responseType": "CandleStick",
        "ticker": "SBER", "classCode": "TQBR", "timeFrame": "M1",
        "open":  244.20, "close": 244.50,
        "high":  244.70, "low":   243.90,
        "volume": 3200,
        "dateTime": "2024-11-10T10:30:00.000Z" }

      (* Error *)
      { "responseType": "CandleStick",
        "errors": [ { "message": "...", "code": "INCORRECT_JSON" } ] }
    ]}

    OHLCV fields arrive as JSON numbers. *)

open Core

(** Build the subscribe (or unsubscribe) envelope for the candles
    stream. [subscribe_type] is [0] for SUBSCRIBE and [1] for
    UNSUBSCRIBE; [data_type] is always [1] for candles. *)
let candle_message ~subscribe_type ~class_code ~ticker ~timeframe : Yojson.Safe.t =
  `Assoc
    [
      ("subscribeType", `Int subscribe_type);
      ("dataType", `Int 1);
      (* 1 = candles *)
      ("timeFrame", `String (Rest.timeframe_wire timeframe));
      ( "instruments",
        `List [ `Assoc [ ("classCode", `String class_code); ("ticker", `String ticker) ] ]
      );
    ]

let subscribe_last_candle_message ~class_code ~ticker ~timeframe =
  candle_message ~subscribe_type:0 ~class_code ~ticker ~timeframe

let unsubscribe_last_candle_message ~class_code ~ticker ~timeframe =
  candle_message ~subscribe_type:1 ~class_code ~ticker ~timeframe

type event =
  | Candle_ev of { instrument : Instrument.t; timeframe : Timeframe.t; candle : Candle.t }
  | Subscribe_ack of {
      instrument : Instrument.t;
      timeframe : Timeframe.t;
      subscribe_type : int;  (** 0 — subscribe, 1 — unsubscribe *)
    }
  | Error_ev of { code : string; message : string }
  | Other of Yojson.Safe.t

(** Map BCS's [timeFrame] strings (M1 … MN) back into our enum. Same
    table as [Rest.timeframe_wire] in reverse. *)
let timeframe_of_string : string -> Timeframe.t option = function
  | "M1" -> Some M1
  | "M5" -> Some M5
  | "M15" -> Some M15
  | "M30" -> Some M30
  | "H1" -> Some H1
  | "H4" -> Some H4
  | "D" -> Some D1
  | "W" -> Some W1
  | "MN" -> Some MN1
  | _ -> None

let num_field k j =
  let open Yojson.Safe.Util in
  match member k j with
  | `Float f -> Decimal.of_float f
  | `Int n -> Decimal.of_int n
  | `String s -> Decimal.of_string s
  | `Intlit s -> Decimal.of_string s
  | _ -> Decimal.zero

let instrument_from ~ticker ~class_code =
  Instrument.make ~ticker:(Ticker.of_string ticker) ~venue:(Mic.of_string "MISX")
    ~board:(Board.of_string class_code) ()

let event_of_json (j : Yojson.Safe.t) : event =
  let open Yojson.Safe.Util in
  (* Error payload is flagged by a non-empty [errors] array regardless
     of [responseType]; surface the first entry as a plain error event
     so callers can log it without digging into the raw JSON. *)
  let error_info =
    match member "errors" j with
    | `List (e :: _) ->
        let code =
          match member "code" e with
          | `String s -> s
          | _ -> ""
        in
        let message =
          match member "message" e with
          | `String s -> s
          | _ -> ""
        in
        Some (code, message)
    | _ -> None
  in
  match error_info with
  | Some (code, message) -> Error_ev { code; message }
  | None -> (
      match
        ( member "responseType" j,
          member "ticker" j,
          member "classCode" j,
          member "timeFrame" j )
      with
      | `String "CandleStick", `String ticker, `String class_code, `String tf ->
          let timeframe = Option.value (timeframe_of_string tf) ~default:Timeframe.H1 in
          let instrument = instrument_from ~ticker ~class_code in
          let ts =
            match member "dateTime" j with
            | `String s -> Infra_common.Iso8601.parse s
            | _ -> 0L
          in
          let candle =
            Candle.make ~ts ~open_:(num_field "open" j) ~high:(num_field "high" j)
              ~low:(num_field "low" j) ~close:(num_field "close" j)
              ~volume:(num_field "volume" j)
          in
          Candle_ev { instrument; timeframe; candle }
      | `String "CandleStickSuccess", `String ticker, `String class_code, `String tf ->
          let timeframe = Option.value (timeframe_of_string tf) ~default:Timeframe.H1 in
          let instrument = instrument_from ~ticker ~class_code in
          let subscribe_type =
            match member "subscribeType" j with
            | `Int n -> n
            | _ -> 0
          in
          Subscribe_ack { instrument; timeframe; subscribe_type }
      | _ -> Other j)
