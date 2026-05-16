type t = int

let of_int n =
  if n <= 0 then invalid_arg "Placement_id.of_int: must be positive";
  n

let to_int n = n
let equal = Int.equal
let compare = Int.compare
