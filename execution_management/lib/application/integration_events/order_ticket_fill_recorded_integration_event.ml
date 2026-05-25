module Completed = Execution_management.Order_ticket.Events.Ticket_completed
module Values = Execution_management.Order_ticket.Values

include Order_ticket_fill_recorded_integration_event_t
include Order_ticket_fill_recorded_integration_event_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

(** Build the IE once, from the aggregate's terminal
    [Ticket_completed] event, carrying the {b cumulative} execution
    of the whole ticket: total filled quantity, the
    volume-weighted average fill price, and the total fees. The
    saga turns this single fact into one [Commit_fill_command] that
    settles the reservation in full — there is no per-leg commit. *)
let of_domain ~correlation_id (e : Completed.t) : t =
  let p = e.progress in
  {
    correlation_id;
    ticket_id = Values.Ticket_id.to_int e.ticket_id;
    reservation_id = Values.Reservation_id.to_int e.reservation_id;
    fill_quantity = Decimal.to_string p.cumulative_filled;
    fill_price = Decimal.to_string (Values.Progress.volume_weighted_average_price p);
    fee = Decimal.to_string p.total_fees;
    occurred_at = Datetime.Iso8601.format e.occurred_at;
  }
