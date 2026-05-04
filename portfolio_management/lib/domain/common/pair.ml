open Core

type t = { a : Instrument.t; b : Instrument.t }

let make ~a ~b =
  if Instrument.equal a b then
    invalid_arg
      (Printf.sprintf "Pair.make: a and b must be distinct (got %s)"
         (Instrument.to_qualified a));
  { a; b }

let a p = p.a
let b p = p.b

let equal p q = Instrument.equal p.a q.a && Instrument.equal p.b q.b

let contains p i = Instrument.equal p.a i || Instrument.equal p.b i
