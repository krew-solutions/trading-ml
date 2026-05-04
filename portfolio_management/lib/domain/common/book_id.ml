type t = string

let max_length = 64

let of_string raw =
  let s = String.trim raw in
  if s = "" then invalid_arg "Book_id.of_string: empty";
  if String.length s > max_length then
    invalid_arg (Printf.sprintf "Book_id.of_string: %S — exceeds %d bytes" raw max_length);
  s

let to_string s = s
let equal = String.equal
let compare = String.compare
let hash = Hashtbl.hash
let pp ppf s = Format.pp_print_string ppf s
