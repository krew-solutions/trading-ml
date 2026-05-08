(** Inbound mirror of an upstream "cash changed" integration event.
    Used by {!Factory.build} to update the kill switch's
    peak-equity baseline. Forward-looking: today Account does not
    yet publish this. *)

type t = {
  book_id : string;
  delta : string;
  new_balance : string;
  occurred_at : string;
  cause : string;
}
[@@deriving yojson]
