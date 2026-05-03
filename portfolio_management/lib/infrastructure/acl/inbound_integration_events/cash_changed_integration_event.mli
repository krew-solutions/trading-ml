(** PM-side mirror of the (future) Account BC "cash changed"
    integration event. Counterpart of
    {!Position_changed_integration_event.t}. *)

type t = {
  book_id : string;
  delta : string;  (** signed Decimal string *)
  new_balance : string;  (** signed Decimal string *)
  occurred_at : string;  (** ISO-8601 *)
  cause : string;
}
[@@deriving yojson]
