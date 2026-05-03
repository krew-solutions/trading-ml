open Core

type change = { instrument : Instrument.t; previous_qty : Decimal.t; new_qty : Decimal.t }

type t = {
  book_id : Shared.Book_id.t;
  source : string;
  proposed_at : int64;
  changed : change list;
}
