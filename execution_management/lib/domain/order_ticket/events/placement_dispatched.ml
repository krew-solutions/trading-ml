type t = {
  ticket_id : Values.Ticket_id.t;
  placement_id : Placement.Values.Placement_id.t;
  quantity : Decimal.t;
  kind : Placement.Values.Order_kind.t;
  tif : Placement.Values.Tif.t;
  occurred_at : int64;
}

let make ~ticket_id ~placement_id ~quantity ~kind ~tif ~occurred_at =
  { ticket_id; placement_id; quantity; kind; tif; occurred_at }
