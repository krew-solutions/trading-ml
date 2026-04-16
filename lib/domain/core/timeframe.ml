(** Bar aggregation period. *)

type t =
  | M1 | M5 | M15 | M30
  | H1 | H4
  | D1 | W1 | MN1

let to_seconds = function
  | M1 -> 60 | M5 -> 300 | M15 -> 900 | M30 -> 1800
  | H1 -> 3600 | H4 -> 14400
  | D1 -> 86400 | W1 -> 604800 | MN1 -> 2592000

let to_string = function
  | M1 -> "M1" | M5 -> "M5" | M15 -> "M15" | M30 -> "M30"
  | H1 -> "H1" | H4 -> "H4"
  | D1 -> "D1" | W1 -> "W1" | MN1 -> "MN1"

let of_string = function
  | "M1" -> M1 | "M5" -> M5 | "M15" -> M15 | "M30" -> M30
  | "H1" -> H1 | "H4" -> H4
  | "D1" -> D1 | "W1" -> W1 | "MN1" -> MN1
  | s -> invalid_arg ("Timeframe.of_string: " ^ s)

let yojson_of_t t = `String (to_string t)
let t_of_yojson = function
  | `String s -> of_string s
  | j -> invalid_arg ("Timeframe.t_of_yojson: " ^ Yojson.Safe.to_string j)
