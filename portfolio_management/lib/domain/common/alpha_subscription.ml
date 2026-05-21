open Core

type t = {
  alpha_source_id : Alpha_source_id.t;
  instrument : Instrument.t;
  book_id : Book_id.t;
}

let make ~alpha_source_id ~instrument ~book_id = { alpha_source_id; instrument; book_id }

let equal a b =
  Alpha_source_id.equal a.alpha_source_id b.alpha_source_id
  && Instrument.equal a.instrument b.instrument
  && Book_id.equal a.book_id b.book_id
