(** Integration event: a fill was observed against a working order
    in paper_broker's book. Published on
    [in-memory://broker.order-filled] after a successful
    [apply_bar_command_workflow] match.

    Carries the actuals of the fill plus the cumulative new total
    filled, so Account / the EMS saga can commit the matching
    reservation atomically. *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier of the originating
          [submit_order_command] (process metadata, recovered from
          the application correlation log since the bar that
          produced this fill carries no correlation_id of its
          own). *)
  reservation_id : int;
      (** Client's identifier of the order, sourced from the Domain
          {!Paper_broker.Order.Events.Order_filled.reservation_id}.
          Account uses it to locate the matching ledger state on
          [commit_fill_command]. *)
  id : string;
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

type domain = Paper_broker.Order.Events.Order_filled.t

val of_domain : correlation_id:string -> domain -> t
