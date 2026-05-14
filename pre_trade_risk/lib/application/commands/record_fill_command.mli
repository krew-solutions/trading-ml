(** Inbound command to the pre_trade_risk BC: "absorb a fill
    reported by Account."

    Driven by the inbound ACL handler subscribing to
    [in-memory://account.reservation-filled]. Carries the full
    transactional effect — both the new cash balance and the new
    position snapshot — in one atomic payload, so [Risk_view]
    advances atomically without exposing a transient state that
    violates [equity = cash + Σ qty × mark]. *)

type t = {
  book_id : string;
  symbol : string;  (** Qualified instrument: [TICKER@MIC[/BOARD]]. *)
  new_position_quantity : string;
      (** Signed Decimal string; ["0"] denotes a closed position. *)
  new_avg_price : string;
      (** Non-negative Decimal string; ["0"] when
          [new_position_quantity] is ["0"]. *)
  new_cash : string;  (** Signed Decimal string; may be negative under margin. *)
  occurred_at : string;  (** ISO-8601. *)
}
[@@deriving yojson]
