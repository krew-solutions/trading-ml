(** JSON encoders for the HTTP API. Stable format consumed by the Angular UI. *)

open Core

let ts_field (ts : int64) : string * Yojson.Safe.t =
  "ts", `Intlit (Int64.to_string ts)

let candle_json (c : Candle.t) : Yojson.Safe.t =
  `Assoc [
    ts_field c.ts;
    "open",   `Float (Decimal.to_float c.open_);
    "high",   `Float (Decimal.to_float c.high);
    "low",    `Float (Decimal.to_float c.low);
    "close",  `Float (Decimal.to_float c.close);
    "volume", `Float (Decimal.to_float c.volume);
  ]

let candles_json (cs : Candle.t list) : Yojson.Safe.t =
  `Assoc [ "candles", `List (List.map candle_json cs) ]

(** Compute an indicator series over the full candle list for charting. *)
let indicator_series (candles : Candle.t list) (spec : Indicators.Registry.spec)
  (params : (string * Indicators.Registry.param) list) : Yojson.Safe.t =
  let ind = spec.build params in
  let _, points =
    List.fold_left (fun (ind, acc) c ->
      let ind' = Indicators.Indicator.update ind c in
      let pt : Yojson.Safe.t =
        match Indicators.Indicator.value ind' with
        | Some (_, vs) ->
          `Assoc (ts_field c.ts ::
                  List.mapi (fun i v ->
                    Printf.sprintf "v%d" i, `Float v) vs)
        | None -> `Assoc [ts_field c.ts; "v0", `Null]
      in
      ind', pt :: acc)
      (ind, []) candles
  in
  `Assoc [
    "name", `String spec.name;
    "points", `List (List.rev points);
  ]

let signal_json (s : Signal.t) : Yojson.Safe.t =
  `Assoc [
    ts_field s.ts;
    "action", `String (Signal.action_to_string s.action);
    "strength", `Float s.strength;
    "reason", `String s.reason;
  ]

let backtest_result_json (r : Engine.Backtest.result) : Yojson.Safe.t =
  `Assoc [
    "num_trades", `Int r.num_trades;
    "total_return", `Float r.total_return;
    "max_drawdown", `Float r.max_drawdown;
    "final_cash", `Float (Decimal.to_float r.final.cash);
    "realized_pnl", `Float (Decimal.to_float r.final.realized_pnl);
    "equity_curve",
      `List (List.map (fun (t, eq) ->
        `Assoc [ ts_field t; "equity", `Float (Decimal.to_float eq) ])
        r.equity_curve);
    "fills",
      `List (List.map (fun (f : Engine.Backtest.fill) ->
        `Assoc [
          ts_field f.ts;
          "side", `String (Side.to_string f.side);
          "quantity", `Float (Decimal.to_float f.quantity);
          "price", `Float (Decimal.to_float f.price);
          "fee", `Float (Decimal.to_float f.fee);
          "reason", `String f.reason;
        ]) r.fills);
  ]

let indicators_catalog () : Yojson.Safe.t =
  `List (List.map (fun s ->
    `Assoc [
      "name", `String s.Indicators.Registry.name;
      "params", `List (List.map (fun (k, p) ->
        let kind, default = match p with
          | Indicators.Registry.Int n -> "int", `Int n
          | Float f -> "float", `Float f
        in
        `Assoc ["name", `String k; "type", `String kind; "default", default])
        s.Indicators.Registry.params)
    ]) Indicators.Registry.specs)

let order_kind_json (k : Order.kind) : Yojson.Safe.t =
  match k with
  | Market -> `Assoc [ "type", `String "MARKET" ]
  | Limit p -> `Assoc [
      "type",  `String "LIMIT";
      "price", `Float (Decimal.to_float p);
    ]
  | Stop p -> `Assoc [
      "type",  `String "STOP";
      "price", `Float (Decimal.to_float p);
    ]
  | Stop_limit { stop; limit } -> `Assoc [
      "type",        `String "STOP_LIMIT";
      "stop_price",  `Float (Decimal.to_float stop);
      "limit_price", `Float (Decimal.to_float limit);
    ]

let order_json (o : Order.t) : Yojson.Safe.t =
  `Assoc [
    "client_order_id", `String o.client_order_id;
    "id",              `String o.id;
    "instrument",      `String (Instrument.to_qualified o.instrument);
    "side",            `String (Side.to_string o.side);
    "quantity",        `Float (Decimal.to_float o.quantity);
    "filled",          `Float (Decimal.to_float o.filled);
    "remaining",       `Float (Decimal.to_float o.remaining);
    "status",          `String (Order.status_to_string o.status);
    "tif",             `String (Order.tif_to_string o.tif);
    "kind",            order_kind_json o.kind;
    ts_field o.created_ts;
  ]

let orders_json (os : Order.t list) : Yojson.Safe.t =
  `Assoc [ "orders", `List (List.map order_json os) ]

(** Accept either JSON int or float for numeric fields — UI uses float,
    CLI may send ints for lot-sized quantities. *)
let to_decimal (j : Yojson.Safe.t) : Decimal.t =
  match j with
  | `Int n   -> Decimal.of_int n
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
  let side = match j |> member "side" |> to_string |> String.uppercase_ascii with
    | "BUY"  -> Side.Buy
    | "SELL" -> Side.Sell
    | s -> failwith ("unknown side: " ^ s)
  in
  let quantity = to_decimal (member "quantity" j) in
  let kind_obj = member "kind" j in
  let kind_type =
    match kind_obj with
    | `String s -> String.uppercase_ascii s  (* short form: "MARKET" *)
    | _ -> kind_obj |> member "type" |> to_string |> String.uppercase_ascii
  in
  let field_decimal name =
    let f = member name kind_obj in
    if f = `Null then failwith ("missing " ^ name) else to_decimal f
  in
  let kind : Order.kind = match kind_type with
    | "MARKET" -> Market
    | "LIMIT" -> Limit (field_decimal "price")
    | "STOP"  -> Stop  (field_decimal "price")
    | "STOP_LIMIT" -> Stop_limit {
        stop  = field_decimal "stop_price";
        limit = field_decimal "limit_price";
      }
    | other -> failwith ("unknown kind: " ^ other)
  in
  let tif =
    match
      try member "tif" j |> to_string with _ -> "DAY"
    with
    | s -> match String.uppercase_ascii s with
      | "GTC" -> Order.GTC
      | "DAY" -> Order.DAY
      | "IOC" -> Order.IOC
      | "FOK" -> Order.FOK
      | other -> failwith ("unknown tif: " ^ other)
  in
  let client_order_id = member "client_order_id" j |> to_string in
  {
    instrument = Instrument.of_qualified symbol;
    side; quantity; kind; tif; client_order_id;
  }

let strategies_catalog () : Yojson.Safe.t =
  `List (List.map (fun s ->
    `Assoc [
      "name", `String s.Strategies.Registry.name;
      "params", `List (List.map (fun (k, p) ->
        let kind, default = match p with
          | Strategies.Registry.Int n -> "int", `Int n
          | Float f -> "float", `Float f
          | Bool b -> "bool", `Bool b
          | String s -> "string", `String s
        in
        `Assoc ["name", `String k; "type", `String kind; "default", default])
        s.Strategies.Registry.params);
    ]) Strategies.Registry.specs)
