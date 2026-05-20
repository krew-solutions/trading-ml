open Core

type t = {
  instrument : Instrument.t;
  timeframe : Timeframe.t;
  candle : Candle.t;
}

let num_field k j =
  let open Yojson.Safe.Util in
  match member k j with
  | `Float f -> Decimal.of_float f
  | `Int n -> Decimal.of_int n
  | `String s -> Decimal.of_string s
  | `Intlit s -> Decimal.of_string s
  | _ -> Decimal.zero

let instrument_from ~ticker ~class_code =
  Instrument.make ~ticker:(Ticker.of_string ticker)
    ~venue:(Mic.of_string "MISX")
    ~board:(Board.of_string class_code) ()

let parse (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let ticker = member "ticker" j |> to_string in
  let class_code = member "classCode" j |> to_string in
  let tf = member "timeFrame" j |> to_string in
  let timeframe = Option.value (Wire_timeframe.of_string tf) ~default:Timeframe.H1 in
  let instrument = instrument_from ~ticker ~class_code in
  let ts =
    match member "dateTime" j with
    | `String s -> Datetime.Iso8601.parse s
    | _ -> 0L
  in
  let candle =
    Candle.make ~ts
      ~open_:(num_field "open" j)
      ~high:(num_field "high" j)
      ~low:(num_field "low" j)
      ~close:(num_field "close" j)
      ~volume:(num_field "volume" j)
  in
  { instrument; timeframe; candle }
