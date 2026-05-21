(** Inbound [CandleStick] event — one OHLCV tick on a subscribed
    [(classCode, ticker, timeFrame)]. *)

open Core

type t = { instrument : Instrument.t; timeframe : Timeframe.t; candle : Candle.t }

val parse : Yojson.Safe.t -> t
(** Decode a CandleStick payload. The caller has already
    discriminated on [responseType]. *)
