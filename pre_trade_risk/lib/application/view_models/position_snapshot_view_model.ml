type t = { instrument : Instrument_view_model.t; quantity : string; avg_price : string }
[@@deriving yojson]

type domain = Pre_trade_risk.Risk_view.Values.Position_snapshot.t

let of_domain (p : domain) : t =
  {
    instrument =
      Instrument_view_model.of_domain
        (Pre_trade_risk.Risk_view.Values.Position_snapshot.instrument p);
    quantity =
      Decimal.to_string (Pre_trade_risk.Risk_view.Values.Position_snapshot.quantity p);
    avg_price =
      Decimal.to_string (Pre_trade_risk.Risk_view.Values.Position_snapshot.avg_price p);
  }
