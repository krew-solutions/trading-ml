(** Inbound command to the Portfolio Management BC: "replace the
    target portfolio for [book_id] with the supplied positions."

    Wire-format DTO — primitives only, no domain values. [proposed_at]
    is an ISO-8601 timestamp parsed by the handler. [target_qty] is
    a signed Decimal string (positive long, negative short, zero flat).

    Triggered by:
      - a portfolio_construction policy producing a {!Target_proposal}
        (composition root pipes through this command);
      - an external override (CLI / future REST). *)

type position = {
  instrument : string;  (** [TICKER@MIC[/BOARD]] *)
  target_qty : string;  (** signed Decimal string *)
}
[@@deriving yojson]

type t = {
  book_id : string;
  source : string;
  proposed_at : string;  (** ISO-8601 *)
  positions : position list;
}
[@@deriving yojson]
