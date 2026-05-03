(** Inbound command to the Portfolio Management BC: "project an
    upstream position change into the actual_portfolio model."

    Triggered by an inbound integration event from the Account BC
    (once Account starts publishing Position_changed events) carrying
    [book_id], a leg, and the new authoritative quantity / mean price.
    The wire-format DTO mirrors the inbound IE — same primitives,
    same field names. *)

type t = {
  book_id : string;
  instrument : string;  (** [TICKER@MIC[/BOARD]] *)
  delta_qty : string;  (** signed Decimal string *)
  new_qty : string;  (** signed Decimal string *)
  avg_price : string;  (** non-negative Decimal string *)
  occurred_at : string;  (** ISO-8601 *)
}
[@@deriving yojson]
