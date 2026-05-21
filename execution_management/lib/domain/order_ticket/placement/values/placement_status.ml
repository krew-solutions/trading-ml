type t = Pending | Working | Filled | Rejected | Unreachable | Cancelled

let is_terminal = function
  | Filled | Rejected | Unreachable | Cancelled -> true
  | Pending | Working -> false

let to_string = function
  | Pending -> "Pending"
  | Working -> "Working"
  | Filled -> "Filled"
  | Rejected -> "Rejected"
  | Unreachable -> "Unreachable"
  | Cancelled -> "Cancelled"
