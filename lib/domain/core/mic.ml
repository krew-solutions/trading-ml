type t = string

let is_alnum c = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

let of_string raw =
  let s = String.uppercase_ascii (String.trim raw) in
  if String.length s <> 4 then
    invalid_arg (Printf.sprintf "Mic.of_string: %S — expected 4 chars" raw);
  String.iter
    (fun c ->
      if not (is_alnum c) then
        invalid_arg (Printf.sprintf "Mic.of_string: %S — non-alphanumeric" raw))
    s;
  s

let to_string s = s
let equal = String.equal
let compare = String.compare
let hash = Hashtbl.hash
let pp ppf s = Format.pp_print_string ppf s
