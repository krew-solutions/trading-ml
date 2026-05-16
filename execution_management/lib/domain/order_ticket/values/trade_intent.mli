(** Trader-intent value object — the input that opens an
    OrderTicket. Carries WHAT to execute (instrument, side,
    total quantity, book); HOW to execute lives in the sibling
    {!Execution_directive.t}.

    Invariants:
    - [total_quantity > 0]. *)

(*@ function dec_raw (d : Decimal.t) : integer *)

type t = private {
  book_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  total_quantity : Decimal.t;
}

val make :
  book_id:string ->
  instrument:Core.Instrument.t ->
  side:Core.Side.t ->
  total_quantity:Decimal.t ->
  t
(** Raises [Invalid_argument] when [total_quantity ≤ 0]. *)
(*@ r = make ~book_id ~instrument ~side ~total_quantity
    requires dec_raw total_quantity > 0
    ensures r.book_id = book_id
    ensures r.instrument = instrument
    ensures r.side = side
    ensures dec_raw r.total_quantity = dec_raw total_quantity *)
