module Opened = Execution_management.Order_ticket.Events.Ticket_opened

include Order_ticket_opened_integration_event_t
include Order_ticket_opened_integration_event_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

let of_domain ~correlation_id (e : Opened.t) : t =
  {
    correlation_id;
    ticket_id = Execution_management.Order_ticket.Values.Ticket_id.to_int e.ticket_id;
    reservation_id =
      Execution_management.Order_ticket.Values.Reservation_id.to_int e.reservation_id;
    book_id = e.intent.book_id;
    instrument = Instrument_view_model.of_domain e.intent.instrument;
    side = Core.Side.to_string e.intent.side;
    total_quantity = Decimal.to_string e.intent.total_quantity;
    directive = Execution_directive_view_model.of_domain e.directive;
    occurred_at = Datetime.Iso8601.format e.occurred_at;
  }
