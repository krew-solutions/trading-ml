(** JSON encoders for the HTTP API. Per-resource projection goes
    through {!Queries.View_model.S} modules: domain value →
    [of_domain] → [yojson_of_t]. HTTP-response framing (the
    [{"candles": [...]}] wrappers, catalogs, catch-all shapes)
    stays here. *)

open Core
open Queries

let ts_field (ts : int64) : string * Yojson.Safe.t = ("ts", `Intlit (Int64.to_string ts))

(** Thin wrapper used for readability at call sites:
    [project Candle_view_model c] instead of a longer
    [Candle_view_model.yojson_of_t (Candle_view_model.of_domain c)]. *)
let project (type d) (module V : View_model.S with type domain = d) (x : d) :
    Yojson.Safe.t =
  V.yojson_of_t (V.of_domain x)

let candle_json (c : Candle.t) : Yojson.Safe.t = project (module Candle_view_model) c

(** {1 PlaceOrder HTTP outcomes}

    Each outcome of the [POST /api/orders] flow gets a stable,
    discriminated JSON shape. The [status] field is the
    primary discriminator; the rest of the fields are
    outcome-specific. *)

let order_accepted_json
    (ev : Account_integration_events.Amount_reserved_integration_event.t)
    (oa : Broker_integration_events.Order_accepted_integration_event.t) : Yojson.Safe.t =
  `Assoc
    [
      ("status", `String "placed");
      ("reservation_id", `Int ev.reservation_id);
      ("order", Broker_queries.Order_view_model.yojson_of_t oa.broker_order);
    ]

let order_rejected_json
    (ev : Account_integration_events.Amount_reserved_integration_event.t)
    (orj : Broker_integration_events.Order_rejected_integration_event.t) : Yojson.Safe.t =
  `Assoc
    [
      ("status", `String "rejected_by_broker");
      ("reservation_id", `Int ev.reservation_id);
      ("reason", `String orj.reason);
    ]

let order_unreachable_json
    (ev : Account_integration_events.Amount_reserved_integration_event.t)
    (ou : Broker_integration_events.Order_unreachable_integration_event.t) : Yojson.Safe.t
    =
  `Assoc
    [
      ("status", `String "broker_unreachable");
      ("reservation_id", `Int ev.reservation_id);
      ("reason", `String ou.reason);
    ]

let reservation_rejected_json
    (rj : Account_integration_events.Reservation_rejected_integration_event.t) :
    Yojson.Safe.t =
  `Assoc [ ("status", `String "rejected_by_account"); ("reason", `String rj.reason) ]

let candles_json (cs : Candle.t list) : Yojson.Safe.t =
  `Assoc [ ("candles", `List (List.map candle_json cs)) ]

(** Compute an indicator series over the full candle list for
    charting. Indicators are computed projections, not entities,
    so no VM — built directly from the registry spec. *)
let indicator_series
    (candles : Candle.t list)
    (spec : Indicators.Registry.spec)
    (params : (string * Indicators.Registry.param) list) : Yojson.Safe.t =
  let ind = spec.build params in
  let _, points =
    List.fold_left
      (fun (ind, acc) c ->
        let ind' = Indicators.Indicator.update ind c in
        let pt : Yojson.Safe.t =
          match Indicators.Indicator.value ind' with
          | Some (_, vs) ->
              `Assoc
                (ts_field c.ts
                :: List.mapi (fun i v -> (Printf.sprintf "v%d" i, `Float v)) vs)
          | None -> `Assoc [ ts_field c.ts; ("v0", `Null) ]
        in
        (ind', pt :: acc))
      (ind, []) candles
  in
  `Assoc [ ("name", `String spec.name); ("points", `List (List.rev points)) ]

let signal_json (s : Signal.t) : Yojson.Safe.t = project (module Signal_view_model) s

let backtest_result_json (r : Engine.Backtest.result) : Yojson.Safe.t =
  project (module Backtest_result_view_model) r

let indicators_catalog () : Yojson.Safe.t =
  `List
    (List.map
       (fun s ->
         `Assoc
           [
             ("name", `String s.Indicators.Registry.name);
             ( "params",
               `List
                 (List.map
                    (fun (k, p) ->
                      let kind, default =
                        match p with
                        | Indicators.Registry.Int n -> ("int", `Int n)
                        | Float f -> ("float", `Float f)
                      in
                      `Assoc
                        [
                          ("name", `String k); ("type", `String kind); ("default", default);
                        ])
                    s.Indicators.Registry.params) );
           ])
       Indicators.Registry.specs)

(** Accept either JSON int or float for numeric fields — UI uses float,
    CLI may send ints for lot-sized quantities. *)
let to_decimal (j : Yojson.Safe.t) : Decimal.t =
  match j with
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s | `String s -> Decimal.of_string s
  | _ -> failwith "expected number"

type place_order_request = {
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  kind : Order.kind;
  tif : Order.time_in_force;
  client_order_id : string;
}

let place_order_of_json (j : Yojson.Safe.t) : place_order_request =
  let open Yojson.Safe.Util in
  let symbol = j |> member "symbol" |> to_string in
  let side =
    match j |> member "side" |> to_string |> String.uppercase_ascii with
    | "BUY" -> Side.Buy
    | "SELL" -> Side.Sell
    | s -> failwith ("unknown side: " ^ s)
  in
  let quantity = to_decimal (member "quantity" j) in
  let kind_obj = member "kind" j in
  let kind_type =
    match kind_obj with
    | `String s -> String.uppercase_ascii s (* short form: "MARKET" *)
    | _ -> kind_obj |> member "type" |> to_string |> String.uppercase_ascii
  in
  let field_decimal name =
    let f = member name kind_obj in
    if f = `Null then failwith ("missing " ^ name) else to_decimal f
  in
  let kind : Order.kind =
    match kind_type with
    | "MARKET" -> Market
    | "LIMIT" -> Limit (field_decimal "price")
    | "STOP" -> Stop (field_decimal "price")
    | "STOP_LIMIT" ->
        Stop_limit
          { stop = field_decimal "stop_price"; limit = field_decimal "limit_price" }
    | other -> failwith ("unknown kind: " ^ other)
  in
  let tif =
    match try member "tif" j |> to_string with _ -> "DAY" with
    | s -> (
        match String.uppercase_ascii s with
        | "GTC" -> Order.GTC
        | "DAY" -> Order.DAY
        | "IOC" -> Order.IOC
        | "FOK" -> Order.FOK
        | other -> failwith ("unknown tif: " ^ other))
  in
  let client_order_id = member "client_order_id" j |> to_string in
  {
    instrument = Instrument.of_qualified symbol;
    side;
    quantity;
    kind;
    tif;
    client_order_id;
  }

let strategies_catalog () : Yojson.Safe.t =
  `List
    (List.map
       (fun s ->
         `Assoc
           [
             ("name", `String s.Strategies.Registry.name);
             ( "params",
               `List
                 (List.map
                    (fun (k, p) ->
                      let kind, default =
                        match p with
                        | Strategies.Registry.Int n -> ("int", `Int n)
                        | Float f -> ("float", `Float f)
                        | Bool b -> ("bool", `Bool b)
                        | String s -> ("string", `String s)
                      in
                      `Assoc
                        [
                          ("name", `String k); ("type", `String kind); ("default", default);
                        ])
                    s.Strategies.Registry.params) );
           ])
       Strategies.Registry.specs)
