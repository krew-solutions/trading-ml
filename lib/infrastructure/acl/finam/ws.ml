(** Subscription protocol DTOs for Finam Trade async-api.
    Authoritative reference: [specs/asyncapi/asyncapi-v1.0.0.yaml] in
    the [finam-trade-api] mirror.

    Wire format (client → server) is a single envelope:
    {[
      { "action": "SUBSCRIBE",         (* SUBSCRIBE | UNSUBSCRIBE | UNSUBSCRIBE_ALL *)
        "type":   "BARS",              (* BARS | ORDER_BOOK | QUOTES | ... *)
        "data":   { ... },             (* type-specific *)
        "token":  "<JWT>"              (* required on every message, not in HTTP headers *)
      }
    ]}

    Server → client envelope:
    {[
      { "type": "DATA",                (* DATA | ERROR | EVENT *)
        "subscription_type": "BARS",
        "subscription_key":  "<opt>",
        "timestamp": 1700000000,
        "payload":  { ... }            (* shape depends on subscription_type *)
      }
    ]} *)

open Core

type subscribe =
  | Sub_quotes of Instrument.t list
  | Sub_orderbook of Instrument.t
  | Sub_bars of { instrument : Instrument.t; timeframe : Timeframe.t }
  | Sub_account of string

(** [subscribe_message ~token sub] — full envelope ready to JSON-encode
    and send over the socket. *)
let subscribe_message ~token = function
  | Sub_quotes is ->
      `Assoc
        [
          ("action", `String "SUBSCRIBE");
          ("type", `String "QUOTES");
          ( "data",
            `Assoc
              [
                ( "symbols",
                  `List (List.map (fun i -> `String (Routing.qualify_instrument i)) is) );
              ] );
          ("token", `String token);
        ]
  | Sub_orderbook i ->
      `Assoc
        [
          ("action", `String "SUBSCRIBE");
          ("type", `String "ORDER_BOOK");
          ("data", `Assoc [ ("symbol", `String (Routing.qualify_instrument i)) ]);
          ("token", `String token);
        ]
  | Sub_bars { instrument; timeframe } ->
      `Assoc
        [
          ("action", `String "SUBSCRIBE");
          ("type", `String "BARS");
          ( "data",
            `Assoc
              [
                ("symbol", `String (Routing.qualify_instrument instrument));
                ("timeframe", `String (Rest.timeframe_wire timeframe));
              ] );
          ("token", `String token);
        ]
  | Sub_account account_id ->
      `Assoc
        [
          ("action", `String "SUBSCRIBE");
          ("type", `String "ACCOUNT");
          ("data", `Assoc [ ("account_id", `String account_id) ]);
          ("token", `String token);
        ]

let unsubscribe_message ~token = function
  | Sub_bars { instrument; timeframe } ->
      `Assoc
        [
          ("action", `String "UNSUBSCRIBE");
          ("type", `String "BARS");
          ( "data",
            `Assoc
              [
                ("symbol", `String (Routing.qualify_instrument instrument));
                ("timeframe", `String (Rest.timeframe_wire timeframe));
              ] );
          ("token", `String token);
        ]
  | Sub_quotes is ->
      `Assoc
        [
          ("action", `String "UNSUBSCRIBE");
          ("type", `String "QUOTES");
          ( "data",
            `Assoc
              [
                ( "symbols",
                  `List (List.map (fun i -> `String (Routing.qualify_instrument i)) is) );
              ] );
          ("token", `String token);
        ]
  | Sub_orderbook i ->
      `Assoc
        [
          ("action", `String "UNSUBSCRIBE");
          ("type", `String "ORDER_BOOK");
          ("data", `Assoc [ ("symbol", `String (Routing.qualify_instrument i)) ]);
          ("token", `String token);
        ]
  | Sub_account account_id ->
      `Assoc
        [
          ("action", `String "UNSUBSCRIBE");
          ("type", `String "ACCOUNT");
          ("data", `Assoc [ ("account_id", `String account_id) ]);
          ("token", `String token);
        ]

(** Decoded server-side events. BARS events carry the timeframe
    directly (recovered from [subscription_key], which Finam encodes
    as ["<TICKER>@<MIC>:<TIMEFRAME>"]), so dispatch is exact rather
    than best-effort. *)
type event =
  | Bars of {
      instrument : Instrument.t;
      timeframe : Timeframe.t option;
      bars : Candle.t list;
    }
  | Quote of { instrument : Instrument.t; bid : Decimal.t; ask : Decimal.t; ts : int64 }
  | Error_ev of { code : int; type_ : string; message : string }
  | Lifecycle of { event : string; code : int; reason : string }
  | Other of Yojson.Safe.t

(** Finam's gRPC→REST bridge frequently double-encodes [payload] as a
    JSON string (the gRPC wrapper type [google.protobuf.Value]
    renders nested messages as JSON text). Unwrap so downstream field
    lookups see a real object. *)
let unwrap_payload (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `String s -> ( try Yojson.Safe.from_string s with _ -> `Null)
  | other -> other

(** Parse [subscription_key] formatted as ["<TICKER>@<MIC>:<TIMEFRAME>"]
    (e.g. [SBER@MISX:TIME_FRAME_M1]) into the corresponding typed
    pair. Returns [None] if the format doesn't match. *)
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

let event_of_json (j : Yojson.Safe.t) : event =
  let open Yojson.Safe.Util in
  match member "type" j with
  | `String "DATA" -> (
      let sub_key =
        match member "subscription_key" j with
        | `String s -> parse_subscription_key s
        | _ -> None
      in
      match member "subscription_type" j with
      | `String "BARS" ->
          let payload = unwrap_payload (member "payload" j) in
          let instrument, timeframe =
            match sub_key with
            | Some (i, tf) -> (i, Some tf)
            | None ->
                (* Fallback: recover instrument from payload, timeframe unknown. *)
                let i = Instrument.of_qualified (member "symbol" payload |> to_string) in
                (i, None)
          in
          let bars =
            match member "bars" payload with
            | `List items -> List.map Dto.candle_of_json items
            | _ -> []
          in
          Bars { instrument; timeframe; bars }
      | `String "QUOTES" -> (
          let payload = unwrap_payload (member "payload" j) in
          (* Each quote arrives as one element in payload.quote[]. We surface
          the first; callers that care about deeper books can read raw. *)
          match member "quote" payload with
          | `List (q :: _) ->
              let instrument = Instrument.of_qualified (member "symbol" q |> to_string) in
              let bid = Dto.decimal_field "bid" q in
              let ask = Dto.decimal_field "ask" q in
              let ts =
                match member "timestamp" q with
                | `String s -> Infra_common.Iso8601.parse s
                | `Int n -> Int64.of_int n
                | _ -> 0L
              in
              Quote { instrument; bid; ask; ts }
          | _ -> Other j)
      | _ -> Other j)
  | `String "ERROR" ->
      let info = member "error_info" j in
      Error_ev
        {
          code =
            (match member "code" info with
            | `Int n -> n
            | _ -> 0);
          type_ =
            (match member "type" info with
            | `String s -> s
            | _ -> "");
          message =
            (match member "message" info with
            | `String s -> s
            | _ -> "");
        }
  | `String "EVENT" ->
      let info = member "event_info" j in
      Lifecycle
        {
          event =
            (match member "event" info with
            | `String s -> s
            | _ -> "");
          code =
            (match member "code" info with
            | `Int n -> n
            | _ -> 0);
          reason =
            (match member "reason" info with
            | `String s -> s
            | _ -> "");
        }
  | _ -> Other j
