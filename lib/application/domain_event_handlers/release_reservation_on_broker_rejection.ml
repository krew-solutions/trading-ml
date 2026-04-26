let handle
    ~(portfolio : Engine.Portfolio.t)
    (rejection : Forward_order_to_broker.forward_rejection) :
    ( Engine.Portfolio.t * Engine.Portfolio.reservation_released,
      Engine.Portfolio.release_error )
    Rop.t =
  let id = Forward_order_to_broker.reservation_id_of_rejection rejection in
  Rop.of_result (Engine.Portfolio.try_release portfolio ~id)
