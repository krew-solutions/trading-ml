type t = Flat | Long_spread | Short_spread

let equal a b =
  match (a, b) with
  | Flat, Flat | Long_spread, Long_spread | Short_spread, Short_spread -> true
  | _ -> false
