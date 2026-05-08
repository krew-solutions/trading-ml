(** Inbound command to the pre_trade_risk BC: "absorb a cash change
    reported by Account."

    Driven by the inbound ACL handler subscribing to
    [in-memory://account.cash-changed]. *)

type t = {
  book_id : string;
  delta : string;
  new_balance : string;
  occurred_at : string;  (** ISO-8601. *)
}
[@@deriving yojson]
