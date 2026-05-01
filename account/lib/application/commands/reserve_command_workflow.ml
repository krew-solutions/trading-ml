module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_rejected =
  Account_integration_events.Reservation_rejected_integration_event

let execute
    ~(portfolio : Account.Portfolio.t ref)
    ~(next_reservation_id : unit -> int)
    ~(slippage_buffer : Decimal.t)
    ~(fee_rate : Decimal.t)
    ~(publish_amount_reserved : Amount_reserved.t -> unit)
    ~(publish_reservation_rejected : Reservation_rejected.t -> unit)
    (cmd : Reserve_command.t) : (unit, Reserve_command_handler.handle_error) Rop.t =
  match
    Reserve_command_handler.handle ~portfolio ~next_reservation_id ~slippage_buffer
      ~fee_rate cmd
  with
  | Ok domain_event ->
      Account_domain_event_handlers.Publish_integration_event_on_amount_reserved.handle
        ~publish_amount_reserved domain_event;
      Rop.succeed ()
  | Error errs ->
      List.iter
        (function
          | Reserve_command_handler.Reservation { attempted; error } ->
              publish_reservation_rejected
                Reservation_rejected.
                  {
                    side = Core.Side.to_string attempted.side;
                    instrument =
                      Queries.Instrument_view_model.of_domain attempted.instrument;
                    quantity = Decimal.to_string attempted.quantity;
                    reason = Reserve_command_handler.reservation_error_to_string error;
                  }
          | Reserve_command_handler.Validation _ -> ())
        errs;
      Error errs
