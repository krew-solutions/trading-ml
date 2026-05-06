type t = Up | Down | Flat

let sign = function
  | Up -> 1
  | Down -> -1
  | Flat -> 0

let to_string = function
  | Up -> "UP"
  | Down -> "DOWN"
  | Flat -> "FLAT"

let of_string s =
  match String.uppercase_ascii s with
  | "UP" -> Up
  | "DOWN" -> Down
  | "FLAT" -> Flat
  | other -> invalid_arg (Printf.sprintf "Direction.of_string: %S" other)

let equal a b =
  match (a, b) with
  | Up, Up | Down, Down | Flat, Flat -> true
  | _ -> false
