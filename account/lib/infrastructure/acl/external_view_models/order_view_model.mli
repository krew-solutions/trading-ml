(** Account-side inbound DTO mirror of an order view model.

    Structural-only: identifies the wire fields the upstream Broker BC
    publishes alongside its [order_accepted] integration event.
    [quantity] / [filled] / [remaining] are decimal strings (bit-exact
    roundtrip with the upstream [Decimal.to_string] form);
    [created_ts] is an [int64] epoch counter. No [of_domain] /
    [type domain] — this DTO is consumed (deserialized from an upstream
    BC's outbound JSON), not produced from an Account domain value. Kept
    independent of {!Account_view_models} so that the inbound and outbound
    sides of the wire can evolve their schemas independently. *)

type t = {
  id : string;
  exec_id : string;
  client_order_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : string;
  filled : string;
  remaining : string;
  kind : Order_kind_view_model.t;
  tif : string;
  status : string;
  created_ts : int64;
}
[@@deriving yojson]
