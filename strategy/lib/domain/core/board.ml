type t = string

let of_string raw =
  let s = String.trim raw in
  if s = "" then invalid_arg "Board.of_string: empty";
  String.iter
    (fun c ->
      if c = ' ' || c = '\t' || c = '\n' || c = '\r' then
        invalid_arg (Printf.sprintf "Board.of_string: %S — whitespace" raw))
    s;
  String.uppercase_ascii s

let to_string s = s
let equal = String.equal
let compare = String.compare
let hash = Hashtbl.hash
let pp ppf s = Format.pp_print_string ppf s
