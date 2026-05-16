(** Integration event: Account refused to reserve — invariant
    violation (insufficient cash for a buy, insufficient quantity
    for a sell). Published by {!Reserve_command_workflow} when
    {!Account.Portfolio.try_reserve} returns
    [Insufficient_cash] / [Insufficient_qty].

    No [reservation_id]: nothing was created. Audit and SSE
    consumers still get the attempt context (side / instrument /
    quantity) plus a free-form [reason] string for reporting. *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier echoed verbatim from
        {!Reserve_command.t}.correlation_id. *)
  side : string;
  instrument : Account_view_models.Instrument_view_model.t;
  quantity : string;  (** Decimal string — see {!Reserve_command.t}. *)
  reason : string;
}
[@@deriving yojson]
