(** Inbound mirror of an upstream "cash changed" integration event. *)

type t = {
  book_id : string;
  delta : string;
  new_balance : string;
  occurred_at : string;
  cause : string;
}
[@@deriving yojson]
