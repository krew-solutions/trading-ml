(** Mirror of {!Broker_integration_events.Order_unreachable_integration_event.t}. *)

type t = { correlation_id : string; reservation_id : int; reason : string }
[@@deriving yojson]
