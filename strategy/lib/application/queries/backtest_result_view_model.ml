open Core
module Portfolio_view_model = Account_queries.Portfolio_view_model

type equity_point = { ts : int64; equity : string } [@@deriving yojson]

type t = {
  num_trades : int;
  total_return : float;
  max_drawdown : float;
  final_cash : string;
  realized_pnl : string;
  portfolio : Portfolio_view_model.t;
  fills : Fill_view_model.t list;
  equity_curve : equity_point list;
}
[@@deriving yojson]

type domain = Engine.Backtest.result

let of_domain (r : domain) : t =
  {
    num_trades = r.num_trades;
    total_return = r.total_return;
    max_drawdown = r.max_drawdown;
    final_cash = Decimal.to_string r.final.cash;
    realized_pnl = Decimal.to_string r.final.realized_pnl;
    portfolio = Portfolio_view_model.of_domain r.final;
    fills = List.map Fill_view_model.of_domain r.fills;
    equity_curve =
      List.map (fun (ts, eq) -> { ts; equity = Decimal.to_string eq }) r.equity_curve;
  }
