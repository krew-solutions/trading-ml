(** Integration event: Account refused to reserve — invariant
    violation (insufficient cash for a buy, insufficient quantity
    for a sell). Published by {!Reserve_command_workflow} when
    {!Account.Portfolio.try_reserve} returns
    [Insufficient_cash] / [Insufficient_qty].

    No [reservation_id]: nothing was created. Audit and SSE
    consumers still get the attempt context (side / instrument /
    quantity) plus a free-form [reason] string for reporting. *)

type t = {
  side : string;
  instrument : Queries.Instrument_view_model.t;
  quantity : float;
  reason : string;
}
[@@deriving yojson]
