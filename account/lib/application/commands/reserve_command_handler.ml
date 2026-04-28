module Amount_reserved = Account_integration_events.Amount_reserved_integration_event
module Reservation_rejected = Account_integration_events.Reservation_rejected_integration_event

let parse_side = function
  | "BUY" -> Core.Side.Buy
  | "SELL" -> Core.Side.Sell
  | s -> invalid_arg (Printf.sprintf "side: %S" s)

let reservation_error_to_string = function
  | Account.Portfolio.Insufficient_cash { required; available } ->
      Printf.sprintf "insufficient cash: required %s, available %s"
        (Core.Decimal.to_string required)
        (Core.Decimal.to_string available)
  | Account.Portfolio.Insufficient_qty { required; available } ->
      Printf.sprintf "insufficient quantity: required %s, available %s"
        (Core.Decimal.to_string required)
        (Core.Decimal.to_string available)

let make
    ~(portfolio : Account.Portfolio.t ref)
    ~(next_reservation_id : unit -> int)
    ~(slippage_buffer : float)
    ~(fee_rate : float)
    ~(events_amount_reserved : Amount_reserved.t Bus.Event_bus.t)
    ~(events_reservation_rejected : Reservation_rejected.t Bus.Event_bus.t)
    (cmd : Reserve_command.t) : unit =
  let instrument = Core.Instrument.of_qualified cmd.symbol in
  let side = parse_side (String.uppercase_ascii cmd.side) in
  let quantity = Core.Decimal.of_float cmd.quantity in
  let price = Core.Decimal.of_float cmd.price in
  let id = next_reservation_id () in
  match
    Account.Portfolio.try_reserve !portfolio ~id ~side ~instrument ~quantity ~price
      ~slippage_buffer ~fee_rate
  with
  | Ok (p', ev) ->
      portfolio := p';
      Bus.Event_bus.publish events_amount_reserved
        Amount_reserved.
          {
            reservation_id = ev.reservation_id;
            side = Core.Side.to_string ev.side;
            instrument = Queries.Instrument_view_model.of_domain ev.instrument;
            quantity = Core.Decimal.to_float ev.quantity;
            price = Core.Decimal.to_float ev.price;
            reserved_cash = Core.Decimal.to_float ev.reserved_cash;
          }
  | Error err ->
      Bus.Event_bus.publish events_reservation_rejected
        Reservation_rejected.
          {
            side = Core.Side.to_string side;
            instrument = Queries.Instrument_view_model.of_domain instrument;
            quantity = Core.Decimal.to_float quantity;
            reason = reservation_error_to_string err;
          }
