(** Inbound command to the Account BC: "commit the reservation
    that was earmarked under [reservation_id] using the broker's
    actual fill numbers."

    Triggered by an inbound
    {!Account_external_integration_events.Order_filled_integration_event.t}
    arriving on the [in-memory://broker.order-filled] topic, which
    the saga-driven paper / real broker emits when a venue (or the
    matching simulator) reports a fill. The handler updates
    {!Account.Portfolio.t} via {!Account.Portfolio.commit_fill}
    and the workflow publishes
    {!Account_integration_events.Position_changed_integration_event}
    and {!Account_integration_events.Cash_changed_integration_event}.

    Wire-format DTO — primitives only. Decimals as canonical
    strings (ADR 0007). *)

type t = {
  correlation_id : string;
      (** Saga-instance identifier echoed verbatim from the
        upstream {!Reserve_command}. The Place_order_pm in
        execution_management uses the value as the saga routing
        key; Account echoes it onto every outbound IE produced
        from this command so downstream consumers can correlate
        the position / cash change with the originating intent. *)
  reservation_id : int;
      (** The reservation id Account minted in response to the
        original {!Reserve_command}, echoed through the saga and
        sent back on the fill. Resolves the lookup performed by
        {!Account.Portfolio.commit_fill}; on absence the
        aggregate returns
        [Error (Reservation_not_found _)] and the application
        layer (factory) decides what to do (today: silent drop,
        consistent with the same policy applied to
        [account.release-command]). *)
  quantity : string;
      (** Actual filled quantity, decimal string. Bit-exact
        round-trip via {!Decimal.of_string}. *)
  price : string;  (** Actual fill price, decimal string. *)
  fee : string;
      (** Actual fee charged by the venue / brokerage, decimal
        string. Non-negative. *)
}
[@@deriving yojson]
