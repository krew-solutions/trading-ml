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

let strategies_catalog () : Yojson.Safe.t =
  `List (List.map (fun s ->
    `Assoc [
      "name", `String s.Strategies.Registry.name;
      "params", `List (List.map (fun (k, p) ->
        let kind, default = match p with
          | Strategies.Registry.Int n -> "int", `Int n
          | Float f -> "float", `Float f
          | Bool b -> "bool", `Bool b
        in
        `Assoc ["name", `String k; "type", `String kind; "default", default])
        s.Strategies.Registry.params);
    ]) Strategies.Registry.specs)
