(** Inbound command to the pre_trade_risk BC: "absorb a position
    change reported by Account."

    Driven by the inbound ACL handler subscribing to
    [in-memory://account.position-changed]. The mutation is local —
    pre_trade_risk's view never feeds back into Account; the BCs
    communicate one-way through the event bus. *)

type t = {
  book_id : string;
  symbol : string;  (** Qualified instrument: [TICKER@MIC[/BOARD]]. *)
  delta_qty : string;
  new_qty : string;
  avg_price : string;
  occurred_at : string;  (** ISO-8601. *)
}
[@@deriving yojson]
