(** Domain Event: the aggregate materialised a strategy
    [submit_request] into a Placement, assigned it a fresh
    [Placement_id], and dispatched it (the application-layer
    domain-event handler turns this into a broker
    [Submit_order_command]). *)

type t = {
  ticket_id : Values.Ticket_id.t;
  placement_id : Placement.Values.Placement_id.t;
  quantity : Decimal.t;
  kind : Placement.Values.Order_kind.t;
  tif : Placement.Values.Tif.t;
  occurred_at : int64;
}

val make :
  ticket_id:Values.Ticket_id.t ->
  placement_id:Placement.Values.Placement_id.t ->
  quantity:Decimal.t ->
  kind:Placement.Values.Order_kind.t ->
  tif:Placement.Values.Tif.t ->
  occurred_at:int64 ->
  t
