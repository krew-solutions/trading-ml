module Values = Values

type t = {
  id : Values.Placement_id.t;
  requested_quantity : Decimal.t;
  cumulative_filled : Decimal.t;
  status : Values.Placement_status.t;
  kind : Values.Order_kind.t;
  tif : Values.Tif.t;
}

let pending ~id ~requested_quantity ~kind ~tif =
  if Decimal.compare requested_quantity Decimal.zero <= 0 then
    invalid_arg "Placement.pending: requested_quantity must be positive";
  {
    id;
    requested_quantity;
    cumulative_filled = Decimal.zero;
    status = Values.Placement_status.Pending;
    kind;
    tif;
  }

let acknowledge t =
  if Values.Placement_status.is_terminal t.status then t
  else { t with status = Values.Placement_status.Working }

let apply_fill t ~(fill : Values.Fill_record.t) =
  if Values.Placement_status.is_terminal t.status then t
  else
    let new_filled = Decimal.add t.cumulative_filled fill.quantity in
    if Decimal.compare new_filled t.requested_quantity > 0 then
      invalid_arg
        "Placement.apply_fill: would push cumulative_filled past \
         requested_quantity"
    else
      let status =
        if Decimal.equal new_filled t.requested_quantity then
          Values.Placement_status.Filled
        else Values.Placement_status.Working
      in
      { t with cumulative_filled = new_filled; status }

let reject t =
  if Values.Placement_status.is_terminal t.status then t
  else { t with status = Values.Placement_status.Rejected }

let unreachable t =
  if Values.Placement_status.is_terminal t.status then t
  else { t with status = Values.Placement_status.Unreachable }

let cancel t =
  if Values.Placement_status.is_terminal t.status then t
  else { t with status = Values.Placement_status.Cancelled }

let remaining_quantity t =
  Decimal.sub t.requested_quantity t.cumulative_filled

let is_terminal t = Values.Placement_status.is_terminal t.status
