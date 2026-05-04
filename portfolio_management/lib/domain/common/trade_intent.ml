open Core

type t = {
  book_id : Book_id.t;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
}

let equal p q =
  Book_id.equal p.book_id q.book_id
  && Instrument.equal p.instrument q.instrument
  && p.side = q.side
  && Decimal.equal p.quantity q.quantity
