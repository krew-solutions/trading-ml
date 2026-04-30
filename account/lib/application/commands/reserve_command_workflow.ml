module Portfolio = Account.Portfolio
module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_rejected =
  Account_integration_events.Reservation_rejected_integration_event

let parse_side = function
  | "BUY" -> Core.Side.Buy
  | "SELL" -> Core.Side.Sell
  | s -> invalid_arg (Printf.sprintf "side: %S" s)

let reservation_error_to_string = function
  | Portfolio.Insufficient_cash { required; available } ->
      Printf.sprintf "insufficient cash: required %s, available %s"
        (Core.Decimal.to_string required)
        (Core.Decimal.to_string available)
  | Portfolio.Insufficient_qty { required; available } ->
      Printf.sprintf "insufficient quantity: required %s, available %s"
        (Core.Decimal.to_string required)
        (Core.Decimal.to_string available)

let execute
    ~(portfolio : Portfolio.t ref)
    ~(next_reservation_id : unit -> int)
    ~(slippage_buffer : float)
    ~(fee_rate : float)
    ~(publish_amount_reserved : Amount_reserved.t -> unit)
    ~(publish_reservation_rejected : Reservation_rejected.t -> unit)
    (cmd : Reserve_command.t) : (unit, Portfolio.reservation_error) Rop.t =
  let open Rop in
  let instrument = Core.Instrument.of_qualified cmd.symbol in
  let side = parse_side (String.uppercase_ascii cmd.side) in
  let quantity = Core.Decimal.of_string cmd.quantity in
  let price = Core.Decimal.of_string cmd.price in
  let id = next_reservation_id () in
  match
    Reserve_command_handler.handle ~portfolio ~id ~side ~instrument ~quantity ~price
      ~slippage_buffer ~fee_rate
  with
  | Ok domain_event ->
      Account_domain_event_handlers.Publish_integration_event_on_amount_reserved.handle
        ~publish_amount_reserved domain_event;
      succeed ()
  | Error errs ->
      List.iter
        (fun err ->
          publish_reservation_rejected
            Reservation_rejected.
              {
                side = Core.Side.to_string side;
                instrument = Queries.Instrument_view_model.of_domain instrument;
                quantity = Core.Decimal.to_string quantity;
                reason = reservation_error_to_string err;
              })
        errs;
      Error errs
