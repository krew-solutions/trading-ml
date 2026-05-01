(** Inbound command to the Broker BC: "submit this order to the
    upstream broker."

    Wire-format DTO — primitives + view-model DTOs, no
    {!Core.Instrument.t} / {!Core.Side.t} / {!Decimal.t}.
    Compile-time guarantee via [@@deriving yojson]: the message
    that travels on the InMemory bus today serialises as-is on a
    real (network) bus tomorrow.

    [reservation_id] is the cross-BC saga key — created by Account
    when reserving cash / quantity, propagated by the inbound
    HTTP layer into this command, echoed back by every
    {!Broker_integration_events} variant the handler emits. The
    upstream broker's wire identity ([client_order_id]) is generated
    inside Broker BC by {!Submit_order_command_handler} via
    {!Broker.generate_client_order_id} so the format matches the
    active broker's wire validator (BCS dashed-UUID, Finam
    letters/digits/space); callers do not see or supply it. *)

type t = {
  reservation_id : int;
  symbol : string;
      (** Qualified instrument: [TICKER@MIC[/BOARD]] —
        {!Core.Instrument.of_qualified} round-trips it. *)
  side : string;  (** ["BUY"] | ["SELL"]. *)
  quantity : string;  (** Decimal string accepted by {!Decimal.of_string}. *)
  kind : Queries.Order_kind_view_model.t;
  tif : string;  (** ["GTC"] | ["DAY"] | ["IOC"] | ["FOK"]. *)
}
[@@deriving yojson]
