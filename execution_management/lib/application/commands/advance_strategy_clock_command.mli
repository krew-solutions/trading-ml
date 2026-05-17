(** Command: scheduler-driven clock tick for a single ticket.

    Issued in-process by the application-layer scheduler (PR4b);
    the scheduler queries the ticket_store for all open tickets
    on each interval and issues this command per ticket. The
    workflow forwards the tick to the aggregate's clock-driven
    strategies (TWAP / VWAP / IS). *)

type t = { ticket_id : int }
