(** Inbound command to the Account BC: "earmark cash / quantity
    for a pending order."

    Wire-format DTO — primitives only, no {!Core.Instrument.t} /
    {!Core.Side.t} / {!Core.Decimal.t}.

    [price] is the market-price reference used to compute the
    cash earmark (slippage buffer + fee estimate added by the
    handler from its config). For a limit order it is typically
    the limit price; for a market order it is the latest mark.
    Account does not query upstream for it — the inbound HTTP
    layer supplies it.

    No [reservation_id] field: Account creates the id internally
    (own counter) on success and surfaces it in {!Amount_reserved.t}
    and in the handler's [response]. *)

type t = {
  side : string;  (** ["BUY"] | ["SELL"] (case-insensitive accepted by handler). *)
  symbol : string;
      (** Qualified instrument: [TICKER@MIC[/BOARD]] —
        {!Core.Instrument.of_qualified} round-trips it. *)
  quantity : float;
  price : float;
}
[@@deriving yojson]
