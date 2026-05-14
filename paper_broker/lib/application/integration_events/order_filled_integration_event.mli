(** Integration event: a fill was observed against a working order
    in paper_broker's book. Published on
    [in-memory://broker.order-filled] after a successful
    [apply_bar_command_workflow] match.

    Carries the actuals of the fill plus the cumulative new total
    filled, so Account / the EMS saga can commit the matching
    reservation atomically. *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier echoed from the originating
          [submit_order_command]. *)
  id : string;
  client_order_id : string;
  exec_id : string;
  instrument : Paper_broker_queries.Instrument_view_model.t;
  side : string;
  fill_quantity : string;
  fill_price : string;
  fee : string;
  new_total_filled : string;
  fill_ts : string;  (** ISO-8601. *)
}
[@@deriving yojson]

type domain = Paper_broker.Order.Events.Fill_observed.t

val of_domain : correlation_id:string -> domain -> t
