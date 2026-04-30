(** Inbound command to the Account BC: "earmark cash / quantity
    for a pending order."

    Wire-format DTO — primitives only, no {!Core.Instrument.t} /
    {!Core.Side.t} / {!Core.Decimal.t}.

    [quantity] / [price] are decimal strings (e.g. ["100.10"])
    parsed by the handler with {!Core.Decimal.of_string} —
    bit-exact round-trip. Float on the wire would round-trip
    through {!Core.Decimal.of_float}, defeating the formal
    Why3-verified Decimal semantics.

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
  quantity : string;  (** Decimal string accepted by {!Core.Decimal.of_string}. *)
  price : string;  (** Decimal string accepted by {!Core.Decimal.of_string}. *)
}
[@@deriving yojson]
