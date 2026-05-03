(** Inbound command to PM: "project an upstream cash change into the
    actual_portfolio model." Counterpart of
    {!Change_position_command.t}. *)

type t = {
  book_id : string;
  delta : string;  (** signed Decimal string *)
  new_balance : string;  (** signed Decimal string *)
  occurred_at : string;  (** ISO-8601 *)
}
[@@deriving yojson]
