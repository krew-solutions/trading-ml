(** Open-OrderTicket command. Invoked in-process by the
    {!Order_process_manager} saga on its terminal [Done]
    transition (the OMS→EMS hand-off per ADR-0017).

    Carries the saga's payload verbatim plus the
    Account-supplied [reservation_id] (used as the ticket
    identity). The optional [directive] is the wire-shape
    strategy directive captured from the upstream trader intent
    (kind tag + per-strategy params JSON-object string); absent
    means the handler falls back to {!Values.Execution_directive.Immediate}
    via the internal Execution_policy default. *)

type directive = {
  kind : string;
      (** Strategy tag: IMMEDIATE | TWAP | VWAP | POV | ICEBERG | IMPLEMENTATION_SHORTFALL. *)
  params : string option;
      (** JSON-object string carrying the per-strategy parameters.
          [None] is the only valid shape for [IMMEDIATE]; required
          for every other strategy. *)
}

type t = {
  reservation_id : int;
      (** Account-minted; becomes the ticket_id. *)
  correlation_id : string;
      (** Saga-instance id; echoed verbatim on every emitted
          IE so the saga's downstream readers can correlate. *)
  book_id : string;
  symbol : string;
      (** Qualified instrument: TICKER@MIC[/BOARD]. *)
  side : string;  (** "BUY" | "SELL". *)
  quantity : string;  (** Decimal string. *)
  directive : directive option;
}
