(** Event-driven backtester. Runs a strategy over a historical candle
    stream, routes signals through the risk gate, executes fills at the
    next bar's open ("next-bar execution" avoids look-ahead bias), and
    records an equity curve.

    All state is explicit and the function is referentially transparent:
    given the same inputs, the same trade log comes out. This is the
    property backtest correctness tests rely on. *)

open Core

type fill = {
  ts : int64;
  symbol : Symbol.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
  reason : string;
}

type step = {
  ts : int64;
  equity : Decimal.t;
  cash : Decimal.t;
  signal : Signal.t option;
  fill : fill option;
}

type result = {
  final : Portfolio.t;
  fills : fill list;          (** chronological *)
  equity_curve : (int64 * Decimal.t) list;   (** chronological *)
  max_drawdown : float;
  total_return : float;
  num_trades : int;
}

type config = {
  initial_cash : Decimal.t;
  fee_rate : float;         (** e.g. 0.0005 = 5 bps *)
  limits : Risk.limits;
}

let default_config ?(initial_cash = Decimal.of_int 1_000_000) () =
  { initial_cash; fee_rate = 0.0005;
    limits = Risk.default_limits ~equity:initial_cash }

let apply_signal
    ~config ~portfolio ~symbol ~(next_open : Decimal.t option)
    (sig_ : Signal.t) : Portfolio.t * fill option =
  let mark _ = next_open in
  match next_open with
  | None -> portfolio, None
  | Some price ->
    let equity = Portfolio.equity portfolio mark in
    let open Signal in
    let open_side_opt =
      match sig_.action with
      | Enter_long  -> Some Side.Buy
      | Enter_short -> Some Sell
      | Exit_long   -> Some Sell
      | Exit_short  -> Some Buy
      | Hold -> None
    in
    match open_side_opt with
    | None -> portfolio, None
    | Some side ->
      let qty =
        match sig_.action with
        | Exit_long | Exit_short ->
          (match Portfolio.position portfolio symbol with
           | Some p -> Decimal.abs p.quantity
           | None -> Decimal.zero)
        | _ ->
          Risk.size_from_strength
            ~equity ~price ~limits:config.limits
            ~strength:(Float.max 0.1 sig_.strength)
      in
      if Decimal.is_zero qty then portfolio, None
      else match
        Risk.check ~portfolio ~limits:config.limits
          ~symbol ~side ~quantity:qty ~price ~mark
      with
      | Reject _ -> portfolio, None
      | Accept q ->
        let fee = Decimal.mul (Decimal.mul q price)
                    (Decimal.of_float config.fee_rate) in
        let p' = Portfolio.fill portfolio
                   ~symbol ~side ~quantity:q ~price ~fee in
        p', Some { ts = sig_.ts; symbol; side; quantity = q; price; fee;
                   reason = sig_.reason }

let max_drawdown equity_curve =
  match equity_curve with
  | [] -> 0.0
  | (_, first) :: _ ->
    let peak = ref (Decimal.to_float first) in
    let max_dd = ref 0.0 in
    List.iter (fun (_, eq) ->
      let e = Decimal.to_float eq in
      if e > !peak then peak := e;
      if !peak > 0.0 then
        let dd = (!peak -. e) /. !peak in
        if dd > !max_dd then max_dd := dd
    ) equity_curve;
    !max_dd

(** [run config strategy symbol candles] — candles must be chronological. *)
let run
    ~(config : config)
    ~(strategy : Strategies.Strategy.t)
    ~(symbol : Symbol.t)
    ~(candles : Candle.t list) : result =
  let rec loop strat portfolio pending_sig_opt fills eq_curve = function
    | [] ->
      { final = portfolio;
        fills = List.rev fills;
        equity_curve = List.rev eq_curve;
        max_drawdown = max_drawdown (List.rev eq_curve);
        total_return =
          (let init = Decimal.to_float config.initial_cash in
           let fin =
             Portfolio.equity portfolio (fun _ -> None) |> Decimal.to_float
           in
           if init = 0.0 then 0.0 else (fin -. init) /. init);
        num_trades = List.length fills }
    | c :: rest ->
      (* 1. execute pending signal at this bar's open. *)
      let portfolio, fill_opt =
        match pending_sig_opt with
        | Some s ->
          apply_signal ~config ~portfolio ~symbol
            ~next_open:(Some c.Candle.open_) s
        | None -> portfolio, None
      in
      (* 2. mark-to-market at close. *)
      let mark _ = Some c.Candle.close in
      let eq = Portfolio.equity portfolio mark in
      let eq_curve = (c.ts, eq) :: eq_curve in
      let fills = match fill_opt with
        | Some f -> f :: fills | None -> fills in
      (* 3. feed the strategy for the next bar's decision. *)
      let strat', sig_ = Strategies.Strategy.on_candle strat symbol c in
      let pending =
        if sig_.Signal.action = Signal.Hold then None else Some sig_
      in
      loop strat' portfolio pending fills eq_curve rest
  in
  let p0 = Portfolio.empty ~cash:config.initial_cash in
  loop strategy p0 None [] [] candles
