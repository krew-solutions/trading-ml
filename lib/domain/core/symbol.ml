(** Trading instrument identifier. Opaque to enforce normalisation. *)

type t = string

let of_string s =
  let s = String.trim s in
  if s = "" then invalid_arg "Symbol.of_string: empty"
  else String.uppercase_ascii s

let to_string s = s
let equal = String.equal
let compare = String.compare
let hash = Hashtbl.hash

let yojson_of_t s = `String s
let t_of_yojson = function
  | `String s -> of_string s
  | j -> invalid_arg ("Symbol.t_of_yojson: " ^ Yojson.Safe.to_string j)
