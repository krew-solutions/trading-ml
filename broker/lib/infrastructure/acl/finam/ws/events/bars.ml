open Core

type t = { instrument : Instrument.t; timeframe : Timeframe.t; bars : Candle.t list }

(* [subscription_key] = "<TICKER>@<MIC>:<TIMEFRAME>", e.g.
   "SBER@MISX:TIME_FRAME_M1". Server-synthesised by Finam; verified
   live on 2026-05-22 — present on every BARS DATA, ignored if a
   client tries to set it in SUBSCRIBE. *)
let parse_subscription_key (k : string) : (Instrument.t * Timeframe.t) option =
  match String.index_opt k ':' with
  | None -> None
  | Some i -> (
      let sym = String.sub k 0 i in
      let tf = String.sub k (i + 1) (String.length k - i - 1) in
      try
        let instrument = Instrument.of_qualified sym in
        let timeframe =
          match tf with
          | "TIME_FRAME_M1" -> Timeframe.M1
          | "TIME_FRAME_M5" -> M5
          | "TIME_FRAME_M15" -> M15
          | "TIME_FRAME_M30" -> M30
          | "TIME_FRAME_H1" -> H1
          | "TIME_FRAME_H4" -> H4
          | "TIME_FRAME_D" -> D1
          | "TIME_FRAME_W" -> W1
          | "TIME_FRAME_MN" -> MN1
          | _ -> raise Exit
        in
        Some (instrument, timeframe)
      with _ -> None)

let parse (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let instrument, timeframe =
    match member "subscription_key" j with
    | `String s -> (
        match parse_subscription_key s with
        | Some pair -> pair
        | None -> invalid_arg ("Finam BARS: unparseable subscription_key " ^ s))
    | _ ->
        invalid_arg
          "Finam BARS: envelope missing subscription_key (spec allows it, but Finam \
           empirically always emits it — investigate broker-side contract drift)"
  in
  let payload = Payload.unwrap (member "payload" j) in
  let bars =
    match member "bars" payload with
    | `List items -> List.map Dto.candle_of_json items
    | _ -> []
  in
  { instrument; timeframe; bars }

let to_domain (t : t) : Broker_domain.Remote_broker.Events.Remote_bar_updated.t list =
  List.map
    (fun (candle : Candle.t) ->
      {
        Broker_domain.Remote_broker.Events.Remote_bar_updated.instrument = t.instrument;
        timeframe = t.timeframe;
        candle;
      })
    t.bars
