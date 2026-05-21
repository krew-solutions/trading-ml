module Events = Events
module Requests = Requests

type event =
  | Candle_ev of Events.Candle.t
  | Subscribe_ack of Events.Subscribe_ack.t
  | Error_ev of Events.Error.t
  | Other of Yojson.Safe.t

let timeframe_of_string = Events.Wire_timeframe.of_string

let event_of_json (j : Yojson.Safe.t) : event =
  let open Yojson.Safe.Util in
  match Events.Error.parse j with
  | Some e -> Error_ev e
  | None -> (
      match member "responseType" j with
      | `String "CandleStick" -> Candle_ev (Events.Candle.parse j)
      | `String "CandleStickSuccess" -> Subscribe_ack (Events.Subscribe_ack.parse j)
      | _ -> Other j)
