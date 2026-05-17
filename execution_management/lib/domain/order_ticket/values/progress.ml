type t = {
  total_quantity : Decimal.t;
  cumulative_filled : Decimal.t;
  total_fees : Decimal.t;
}

let empty ~total_quantity =
  if Decimal.compare total_quantity Decimal.zero <= 0 then
    invalid_arg "Progress.empty: total_quantity must be positive";
  {
    total_quantity;
    cumulative_filled = Decimal.zero;
    total_fees = Decimal.zero;
  }

let apply_fill t ~(fill : Placement.Values.Fill_record.t) =
  let new_filled = Decimal.add t.cumulative_filled fill.quantity in
  if Decimal.compare new_filled t.total_quantity > 0 then
    invalid_arg
      "Progress.apply_fill: would push cumulative_filled past total_quantity";
  {
    total_quantity = t.total_quantity;
    cumulative_filled = new_filled;
    total_fees = Decimal.add t.total_fees fill.fee;
  }

let remaining_quantity t = Decimal.sub t.total_quantity t.cumulative_filled

let is_fully_filled t =
  Decimal.equal t.cumulative_filled t.total_quantity
