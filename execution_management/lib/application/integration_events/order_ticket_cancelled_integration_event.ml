module Cancelled = Execution_management.Order_ticket.Events.Ticket_cancelled
module Cancel_reason = Execution_management.Order_ticket.Values.Cancel_reason

include Order_ticket_cancelled_integration_event_t
include Order_ticket_cancelled_integration_event_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

let of_domain ~correlation_id (e : Cancelled.t) : t =
  {
    correlation_id;
    ticket_id = Execution_management.Order_ticket.Values.Ticket_id.to_int e.ticket_id;
    reservation_id =
      Execution_management.Order_ticket.Values.Reservation_id.to_int e.reservation_id;
    reason = Cancel_reason.to_string e.reason;
    progress = Progress_view_model.of_domain e.progress;
    occurred_at = Datetime.Iso8601.format e.occurred_at;
  }
