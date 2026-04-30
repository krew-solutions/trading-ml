(** Read-model DTO for {!Engine.Backtest.result}.

    The domain result carries a full {!Account.Portfolio.t} under
    [final]; the DTO lifts the two headline scalars
    (final cash / realized PnL) next to the aggregate stats and
    exposes the whole portfolio as a nested DTO. Callers that
    need only the summary can ignore [portfolio]. *)

module Portfolio_view_model = Account_queries.Portfolio_view_model

type equity_point = { ts : int64; equity : string } [@@deriving yojson]
(** [equity] is a decimal string accepted by {!Core.Decimal.of_string}. *)

type t = {
  num_trades : int;
  total_return : float;  (** Domain ratio (e.g. [0.12]) — not Decimal-derived. *)
  max_drawdown : float;  (** Domain ratio — not Decimal-derived. *)
  final_cash : string;  (** Decimal string accepted by {!Core.Decimal.of_string}. *)
  realized_pnl : string;
  portfolio : Portfolio_view_model.t;
  fills : Fill_view_model.t list;
  equity_curve : equity_point list;
}
[@@deriving yojson]

type domain = Engine.Backtest.result

val of_domain : domain -> t
