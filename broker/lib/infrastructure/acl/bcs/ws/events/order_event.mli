(** Inbound BCS WebSocket order event — payload of the
    [/orders/execution/ws] channel ("execution-status" in
    BCS-doc Russian terminology, FIX-derived ExecutionReport
    type 8).

    BCS splits the FIX ExecutionReport stream into two
    channels: this one ([execution-status]) emits per-leg fill
    events ([executionType=11 Trade] plus aggregate fill states
    [Partial=1] / [Filled=2]); the sibling
    [transaction-status] emits non-execution lifecycle
    transitions (New, Cancelled, Replaced, Rejected, ...).
    Only [execution-status] is decoded here today — the
    transaction-status channel is a future PR once
    [Order_state_changed] enters the [Broker.event] surface.

    DTO carries every documented wire field verbatim;
    {!to_domain} projects the subset relevant to our
    [Trade_executed] domain event. Non-fill messages on
    this channel parse cleanly but {!to_domain} returns
    [None] for them. *)

open Core

type t = {
  original_client_order_id : string;
      (** The UUID we minted at submit. Survives Modify
          requests; the canonical reverse-lookup key for
          [placement_id]. *)
  client_order_id : string;
      (** Populated only when the order has been modified — it
          is the {b new} cid the venue now addresses the
          order by. Typically empty on first-life events. *)
  message_type : string;
      (** Always ["8"] (FIX ExecutionReport). Carried for
          parity with the wire so future channel additions can
          discriminate. *)
  order_status : string;
      (** Aggregate state of the parent order:
          [0] New, [1] Partial, [2] Filled, [4] Cancelled,
          [5] Replaced, [6] Cancelling, [8] Rejected,
          [9] Replacing, [10] Awaiting confirmation. *)
  execution_type : string;
      (** What triggered this message:
          [0] New, [1] Partial, [2] Filled, [4] Cancelled,
          [5] Replaced, [6] Awaiting cancel, [8] Rejected,
          [9] Suspended, [10] Awaiting new, [11] Trade,
          [12] Status, [13] Corrected. {!to_domain} emits
          [Trade_executed] only when this is ["11"]
          (per-leg fill); other values describe state, not a
          new execution leg. *)
  order_quantity : Decimal.t;  (** Total requested. *)
  executed_quantity : Decimal.t;  (** Cumulative across all legs so far (NOT this leg). *)
  last_quantity : Decimal.t;  (** This leg's contribution; the FIX [LastQty] field. *)
  remained_quantity : Decimal.t;
  ticker : string;
  class_code : string;
  side : Side.t;
  order_type : string;
  average_price : Decimal.t;
      (** Cumulative VWAP across all legs. For the first /
          only leg, equals this leg's fill price. *)
  order_id : string;
  execution_id : string;
      (** Venue-side per-leg id (e.g.
          ["TQBR-Z3fE7c-S-1-1-N"]). Stable, used as the
          [trade_id] on the domain event. *)
  price : Decimal.t;
      (** BCS doc calls this "Order price"; the wire shape
          shows it equal to [average_price] on the sample fill,
          so it may actually be LastPx. Cross-check
          empirically before using as authoritative leg
          price; {!to_domain} prefers [average_price]. *)
  currency : string;
  client_code : string;
  transaction_time : int64;  (** ISO8601 → epoch nanoseconds. *)
  trade_date : string;
  order_number : string;
  accrued_coupon : Decimal.t;
  execution_value : Decimal.t;  (** Total notional value across all legs so far. *)
  commission : Decimal.t;
      (** Cumulative fee. Per-leg fee is not separately
          surfaced; downstream consumers that need it must
          diff across consecutive legs. *)
  security_exchange : string;
  reject_reason : string option;
}

val parse : Yojson.Safe.t -> t option
(** Returns [None] if the envelope is malformed (missing
    [data] subtree, unparseable [side], etc.). Defensive — a
    BCS frame that doesn't match the documented shape is
    logged and dropped at the bridge, not propagated as an
    exception. *)

val is_fill : t -> bool
(** True iff [execution_type = "11"] (FIX [ExecType=F Trade]).
    Convenience predicate used by the bridge to discriminate
    fill events from lifecycle events before resolving
    [placement_id]. *)

val to_domain :
  placement_id:int -> t -> Broker_domain.Remote_broker.Events.Trade_executed.t option
(** Project a BCS execution-status event into a
    [Trade_executed] domain event. Returns [Some] only when
    [execution_type = "11"] (per-leg Trade); other values
    return [None] (lifecycle transitions belong on the
    transaction-status channel and will surface as a
    future [Order_state_changed] event).

    [placement_id] is the caller's reverse-lookup of
    [original_client_order_id] via
    [Placement_handle_store]. Mirrors the
    [Finam.Ws.Events.Trade.to_domain] shape. *)
