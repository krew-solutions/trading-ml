(** Inbound command to the Portfolio Management BC: "commit a fill
    into the [actual_portfolio] model."

    Triggered by an inbound [Reservation_filled_integration_event]
    from the Account BC carrying the full transactional effect — new
    cash balance, new per-instrument position and VWAP — in one
    atomic payload. PM commits them together so consumers never
    observe a transient state that violates
    [equity = cash + Σ qty × mark].

    Wire-format DTO: primitives only. *)

type t = {
  book_id : string;
  instrument : string;  (** [TICKER@MIC[/BOARD]] *)
  new_position_quantity : string;
      (** Signed Decimal string; ["0"] denotes a closed position. *)
  new_avg_price : string;
      (** Non-negative Decimal string; ["0"] when [new_position_quantity]
          is ["0"]. *)
  new_cash : string;  (** Signed Decimal string; may be negative under margin. *)
  occurred_at : string;  (** ISO-8601. *)
}
[@@deriving yojson]
