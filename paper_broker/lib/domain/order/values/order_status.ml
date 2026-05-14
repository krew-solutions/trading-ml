type t = New | Partially_filled | Filled | Cancelled | Rejected | Expired

let is_terminal = function
  | Filled | Cancelled | Rejected | Expired -> true
  | New | Partially_filled -> false

let to_string = function
  | New -> "New"
  | Partially_filled -> "Partially_filled"
  | Filled -> "Filled"
  | Cancelled -> "Cancelled"
  | Rejected -> "Rejected"
  | Expired -> "Expired"
