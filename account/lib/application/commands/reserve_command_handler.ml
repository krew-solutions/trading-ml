let handle
    ~(portfolio : Account.Portfolio.t ref)
    ~(id : int)
    ~(side : Core.Side.t)
    ~(instrument : Core.Instrument.t)
    ~(quantity : Core.Decimal.t)
    ~(price : Core.Decimal.t)
    ~(slippage_buffer : float)
    ~(fee_rate : float) :
    ( Account.Portfolio.Events.Amount_reserved.t,
      Account.Portfolio.reservation_error )
    Rop.t =
  let open Rop in
  let* portfolio', domain_event =
    Account.Portfolio.try_reserve !portfolio ~id ~side ~instrument ~quantity ~price
      ~slippage_buffer ~fee_rate
    |> of_result
  in
  portfolio := portfolio';
  succeed domain_event
