(** Historical replay driver over {!Step}. Folds the shared
    state machine over a candle list, collecting fills and a
    mark-to-market equity curve, then aggregates return / drawdown.

    All the trade-sizing, risk-gating and portfolio-update logic
    lives in {!Step.execute_pending} / {!Step.advance_strategy} —
    {!Live_engine} drives the same primitives on streaming bars,
    so paper P&L converges with a backtest over identical data. *)

open Core

type fill = {
  ts : int64;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
  reason : string;
}

type result = {
  final : Account.Portfolio.t;
  fills : fill list;
  equity_curve : (int64 * Decimal.t) list;
  max_drawdown : float;
  total_return : float;
  num_trades : int;
}

type config = { initial_cash : Decimal.t; fee_rate : Decimal.t; limits : Risk.limits }

let default_config ?(initial_cash = Decimal.of_int 1_000_000) () =
  {
    initial_cash;
    fee_rate = Decimal.of_string "0.0005";
    limits = Risk.default_limits ~equity:initial_cash;
  }

let max_drawdown equity_curve =
  match equity_curve with
  | [] -> 0.0
  | (_, first) :: _ ->
      let peak = ref (Decimal.to_float first) in
      let max_dd = ref 0.0 in
      List.iter
        (fun (_, eq) ->
          let e = Decimal.to_float eq in
          if e > !peak then peak := e;
          if !peak > 0.0 then
            let dd = (!peak -. e) /. !peak in
            if dd > !max_dd then max_dd := dd)
        equity_curve;
      !max_dd

let fill_of_event (instrument : Instrument.t) (e : Pipeline.event) : fill option =
  Option.map
    (fun ((sig_ : Signal.t), (s : Step.settled)) ->
      {
        ts = sig_.ts;
        instrument;
        side = s.side;
        quantity = s.quantity;
        price = s.price;
        fee = s.fee;
        reason = sig_.reason;
      })
    e.settled

let run
    ~(config : config)
    ~(strategy : Strategies.Strategy.t)
    ~(instrument : Instrument.t)
    ~(candles : Candle.t list) : result =
  let step_cfg : Step.config =
    {
      limits = config.limits;
      instrument;
      fee_rate = config.fee_rate;
      auto_commit = true;
      (* synthetic fill — no broker latency *)
    }
  in
  let state0 = Step.make_state ~strategy ~cash:config.initial_cash in
  (* Consume the shared Pipeline: materialise events, then aggregate.
     The same Pipeline.run drives Live_engine — divergence between
     backtest and paper P&L is impossible by construction. *)
  let events =
    candles |> Stream.of_list |> Pipeline.run step_cfg state0 |> Stream.to_list
  in
  let fills = List.filter_map (fill_of_event instrument) events in
  let equity_curve =
    List.map (fun e -> (e.Pipeline.bar.ts, Pipeline.equity_at_close e)) events
  in
  let final_portfolio =
    match List.rev events with
    | e :: _ -> e.Pipeline.state.portfolio
    | [] -> Account.Portfolio.empty ~cash:config.initial_cash
  in
  let total_return =
    let init_c = Decimal.to_float config.initial_cash in
    let fin =
      Account.Portfolio.equity final_portfolio (fun _ -> None) |> Decimal.to_float
    in
    if init_c = 0.0 then 0.0 else (fin -. init_c) /. init_c
  in
  {
    final = final_portfolio;
    fills;
    equity_curve;
    max_drawdown = max_drawdown equity_curve;
    total_return;
    num_trades = List.length fills;
  }
