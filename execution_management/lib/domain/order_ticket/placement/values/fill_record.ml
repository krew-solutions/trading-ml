type t = { quantity : Decimal.t; price : Decimal.t; fee : Decimal.t; ts : int64 }

let make ~quantity ~price ~fee ~ts =
  if Decimal.compare quantity Decimal.zero <= 0 then
    invalid_arg "Fill_record.make: quantity must be positive";
  if Decimal.compare price Decimal.zero < 0 then
    invalid_arg "Fill_record.make: price must be non-negative";
  if Decimal.compare fee Decimal.zero < 0 then
    invalid_arg "Fill_record.make: fee must be non-negative";
  { quantity; price; fee; ts }
