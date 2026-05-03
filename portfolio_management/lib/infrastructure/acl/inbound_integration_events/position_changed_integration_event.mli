(** PM-side mirror of the (future) Account BC "position changed"
    integration event. Account does not yet publish this; the ACL is
    forward-looking — when Account's outbound surface grows to
    include position-level events, the bridge wires Account's
    outbound IE bus into the bus consumed here.

    Structurally identical wire shape to what Account will emit, but
    owned by PM so its projection subscriber listens autonomously
    without importing types across the BC boundary. *)

type t = {
  book_id : string;
  instrument : Portfolio_management_queries.Instrument_view_model.t;
  delta_qty : string;  (** signed Decimal string *)
  new_qty : string;
  avg_price : string;
  occurred_at : string;  (** ISO-8601 *)
  cause : string;  (** ["fill"] | ["external_reconcile"] | ["corporate_action"] *)
}
[@@deriving yojson]
