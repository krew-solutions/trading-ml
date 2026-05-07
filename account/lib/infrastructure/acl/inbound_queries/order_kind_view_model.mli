(** Account-side inbound DTO mirror of an order-kind view model.

    Structural-only: tagged-union projection of [Market | Limit | Stop |
    Stop_limit] flattened to four fields. No [of_domain] / [type domain]
    — this DTO is consumed (deserialized from an upstream BC's outbound
    JSON), not produced from an Account domain value. Kept independent
    of any outbound projection so that the inbound and outbound sides of
    the wire can evolve their schemas independently. *)

type t = {
  type_ : string; [@key "type"]
  price : string option;
  stop_price : string option;
  limit_price : string option;
}
[@@deriving yojson]
