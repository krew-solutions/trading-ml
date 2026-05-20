(** Outbound subscribe / unsubscribe envelope for BCS's
    [/market-data/ws] candle feed.

    Wire format (single envelope, [subscribeType] selects action):
    {[
      { "subscribeType": 0,        (* 0 — subscribe, 1 — unsubscribe *)
        "dataType":      1,        (* 1 — candles *)
        "timeFrame":     "M1",
        "instruments":  [ { "classCode": "TQBR", "ticker": "SBER" } ] }
    ]} *)

open Core

val subscribe :
  class_code:string -> ticker:string -> timeframe:Timeframe.t -> Yojson.Safe.t

val unsubscribe :
  class_code:string -> ticker:string -> timeframe:Timeframe.t -> Yojson.Safe.t
