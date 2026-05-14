(** Time-in-force qualifier carried by every order. Determines how
    long the order remains working before it is expired.

    Paper_broker currently treats all of them uniformly (no
    expiration logic in this cut) but preserves the field so the
    wire format matches real brokerages and future expiration rules
    can be added without disturbing the contract. *)

type t = GTC | DAY | IOC | FOK

val to_string : t -> string
