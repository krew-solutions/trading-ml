module Events = Events
module Requests = Requests
module Payload = Payload

type event =
  | Bars of Events.Bars.t
  | Quote of Events.Quote.t
  | Trades of Events.Trade.update list
  | Error_ev of Events.Error.t
  | Lifecycle of Events.Lifecycle.t
  | Other of Yojson.Safe.t

let event_of_json (j : Yojson.Safe.t) : event =
  let open Yojson.Safe.Util in
  match member "type" j with
  | `String "DATA" -> (
      match member "subscription_type" j with
      | `String "BARS" -> Bars (Events.Bars.parse j)
      | `String "QUOTES" -> (
          match Events.Quote.parse j with
          | Some q -> Quote q
          | None -> Other j)
      | `String "TRADES" -> (
          match Events.Trade.parse j with
          | [] -> Other j
          | xs -> Trades xs)
      | _ -> Other j)
  | `String "ERROR" -> Error_ev (Events.Error.parse j)
  | `String "EVENT" -> Lifecycle (Events.Lifecycle.parse j)
  | _ -> Other j
