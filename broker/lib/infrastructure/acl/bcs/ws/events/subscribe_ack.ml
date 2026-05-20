open Core

type t = {
  instrument : Instrument.t;
  timeframe : Timeframe.t;
  subscribe_type : int;
}

let parse (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let ticker = member "ticker" j |> to_string in
  let class_code = member "classCode" j |> to_string in
  let tf = member "timeFrame" j |> to_string in
  let timeframe =
    Option.value (Wire_timeframe.of_string tf) ~default:Timeframe.H1
  in
  let instrument =
    Instrument.make ~ticker:(Ticker.of_string ticker)
      ~venue:(Mic.of_string "MISX")
      ~board:(Board.of_string class_code) ()
  in
  let subscribe_type =
    match member "subscribeType" j with
    | `Int n -> n
    | _ -> 0
  in
  { instrument; timeframe; subscribe_type }
