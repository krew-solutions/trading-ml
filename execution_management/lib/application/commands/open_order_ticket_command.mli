(** Open-OrderTicket command. Invoked in-process by the
    {!Open_order_ticket_process} saga on its terminal [Done]
    transition (the OMS→EMS hand-off per ADR-0017).

    Carries the saga's payload verbatim plus the
    Account-supplied [reservation_id] (used as the ticket
    identity). The execution_directive is absent on the wire
    today (PR7 extends the upstream contract); the handler
    defaults to {!Values.Execution_directive.Immediate} for now. *)

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
}
