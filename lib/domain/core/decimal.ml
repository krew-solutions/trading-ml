type t = int64

let scale = 8
let unit_ = 100_000_000L (* 10^8 *)

let zero = 0L
let one = unit_

let of_int n = Int64.mul (Int64.of_int n) unit_
let of_float f = Int64.of_float (f *. Int64.to_float unit_)
let to_float x = Int64.to_float x /. Int64.to_float unit_

let add = Int64.add
let sub = Int64.sub
let neg = Int64.neg
let abs = Int64.abs

let mul a b =
  (* (a * b) / unit, via Int128-style split to avoid overflow on typical prices. *)
  let open Int64 in
  let hi = div a unit_ and lo = rem a unit_ in
  add (mul hi b) (div (mul lo b) unit_)

let div a b =
  if Int64.equal b 0L then raise Division_by_zero
  else
    let open Int64 in
    let hi = div a b in
    let rem_ = sub a (mul hi b) in
    add (mul hi unit_) (div (mul rem_ unit_) b)

let compare = Int64.compare
let equal = Int64.equal
let min a b = if compare a b <= 0 then a else b
let max a b = if compare a b >= 0 then a else b

let is_positive x = compare x zero > 0
let is_negative x = compare x zero < 0
let is_zero x = equal x zero

let to_string x =
  let sign = if is_negative x then "-" else "" in
  let x = Int64.abs x in
  let whole = Int64.div x unit_ in
  let frac = Int64.rem x unit_ in
  if Int64.equal frac 0L then Printf.sprintf "%s%Ld" sign whole
  else
    let s = Printf.sprintf "%08Ld" frac in
    let len = String.length s in
    let trim =
      let i = ref (len - 1) in
      while !i >= 0 && s.[!i] = '0' do decr i done;
      String.sub s 0 (!i + 1)
    in
    Printf.sprintf "%s%Ld.%s" sign whole trim

let of_string s =
  let s = String.trim s in
  if s = "" then invalid_arg "Decimal.of_string: empty";
  let neg_, rest =
    if s.[0] = '-' then true, String.sub s 1 (String.length s - 1)
    else if s.[0] = '+' then false, String.sub s 1 (String.length s - 1)
    else false, s
  in
  let whole, frac =
    match String.index_opt rest '.' with
    | None -> rest, ""
    | Some i -> String.sub rest 0 i, String.sub rest (i + 1) (String.length rest - i - 1)
  in
  let frac =
    if String.length frac > scale then String.sub frac 0 scale
    else frac ^ String.make (scale - String.length frac) '0'
  in
  let w = if whole = "" then 0L else Int64.of_string whole in
  let f = if frac = "" then 0L else Int64.of_string frac in
  let v = Int64.add (Int64.mul w unit_) f in
  if neg_ then Int64.neg v else v

