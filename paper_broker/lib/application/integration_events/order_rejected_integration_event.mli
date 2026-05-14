(** Integration event: paper_broker refused a submit_order_command
    at the wire / validation boundary (malformed symbol, invalid
    kind/tif, non-positive quantity, etc.). Published on
    [in-memory://broker.order-rejected].

    Distinct from "broker rejected the order at the venue" — for
    paper_broker, this fires when the request never enters the
    book in the first place. *)

type t = {
  correlation_id : string;
  reservation_id : int;
      (** Opaque correlation token from the originating
          [submit_order_command]. Account releases the reservation
          on this event. *)
  reason : string;
}
[@@deriving yojson]
