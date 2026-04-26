(** Outbound projection of
    {!Domain_event_handlers.Forward_order_to_broker.forward_rejection}.

    Flattened into a single record with a [kind] discriminator
    (["rejected"] / ["unreachable"]) so consumers can branch on
    a string without nested variant parsing. *)

type t = {
  kind : string;
  client_order_id : string;
  reservation_id : int;
  reason : string;
}
[@@deriving yojson]

type domain = Domain_event_handlers.Forward_order_to_broker.forward_rejection

val of_domain : domain -> t
