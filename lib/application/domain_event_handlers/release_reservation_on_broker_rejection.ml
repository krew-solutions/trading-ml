let handle
    ~(portfolio : Account.Portfolio.t)
    (rejection : Forward_order_to_broker.forward_rejection) :
    ( Account.Portfolio.t * Account.Portfolio.reservation_released,
      Account.Portfolio.release_error )
    Rop.t =
  let id = Forward_order_to_broker.reservation_id_of_rejection rejection in
  Rop.of_result (Account.Portfolio.try_release portfolio ~id)
