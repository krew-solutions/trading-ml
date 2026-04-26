type t = string

let is_alnum c = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

(** Expand letters to two digits ([A=10] … [Z=35]) and concatenate
    with the original digits, producing a numeric string used by the
    checksum step. *)
let expand s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter
    (fun c ->
      if c >= '0' && c <= '9' then Buffer.add_char buf c
      else Buffer.add_string buf (string_of_int (Char.code c - Char.code 'A' + 10)))
    s;
  Buffer.contents buf

(** ISIN checksum: Luhn-mod-10 over the {!expand}-ed digits, with
    the rightmost digit being the check digit; doubling starts from
    the second-rightmost. *)
let checksum_ok s =
  let digits = expand s in
  let n = String.length digits in
  let sum = ref 0 in
  for i = 0 to n - 1 do
    let d = Char.code digits.[n - 1 - i] - Char.code '0' in
    let v =
      if i mod 2 = 1 then
        let dd = d * 2 in
        if dd >= 10 then dd - 9 else dd
      else d
    in
    sum := !sum + v
  done;
  !sum mod 10 = 0

let of_string raw =
  let s = String.uppercase_ascii (String.trim raw) in
  if String.length s <> 12 then
    invalid_arg (Printf.sprintf "Isin.of_string: %S — expected 12 chars" raw);
  String.iter
    (fun c ->
      if not (is_alnum c) then
        invalid_arg (Printf.sprintf "Isin.of_string: %S — non-alphanumeric" raw))
    s;
  if not (checksum_ok s) then
    invalid_arg (Printf.sprintf "Isin.of_string: %S — bad checksum" raw);
  s

let to_string s = s
let equal = String.equal
let compare = String.compare
let hash = Hashtbl.hash
let pp ppf s = Format.pp_print_string ppf s
