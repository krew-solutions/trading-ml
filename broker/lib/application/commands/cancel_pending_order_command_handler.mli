(** Command handler for {!Cancel_pending_order_command.t}.

    Two phases:

    - {b Resolve}: call {!Broker.cancel_order_by_placement_id} —
      the adapter looks the saga's [placement_id] up in its
      private placement-handle store. The [None] return is
      surfaced here as {!Placement_not_found}: cancel arrived
      for an order this broker instance never placed (or whose
      index has been lost).
    - {b Dispatch & classify}: if the adapter found the
      placement and the venue acknowledged, its returned
      {!Order_view_model.t}'s [status] is mapped into a
      tri-state outcome:

      - ["CANCELLED"] → {!Cancel_confirmed}
      - ["PENDING_CANCEL"] → {!Cancel_pending}
      - any other status (e.g. ["FILLED"], ["REJECTED"],
        ["EXPIRED"]) → {!Cancel_refused} — the venue
        acknowledged the request but did not (and will not)
        cancel.

      Adapter exceptions (transport, parse) fold into
      {!Unreachable}.

    Publishing the integration event and recording the cancel's
    correlation in the {!Order_command_log} is the enclosing
    {!Cancel_pending_order_command_workflow.execute} pipeline's
    job. *)

type resolution_error =
  | Placement_not_found of int
      (** The adapter has no
          [placement_id ↦ native_handle] mapping for this id —
          either the order was never placed via this broker
          instance, or its index has been lost. *)

val resolution_error_to_string : resolution_error -> string

type broker_outcome =
  | Cancel_confirmed of { cancelled_ts : int64 }
      (** Venue confirmed the cancel — view model [status] is
          ["CANCELLED"]. [cancelled_ts] is from broker's
          injected clock at the moment the response was
          observed. *)
  | Cancel_pending of { cancelled_ts : int64 }
      (** Venue acknowledged the request but the cancel is not
          yet final (status ["PENDING_CANCEL"]). The order may
          still fill before the cancel takes effect;
          reconciliation between live feed and venue is required
          to surface the final state. *)
  | Cancel_refused of { reason : string }
      (** Venue refused (order is already terminal — filled,
          rejected, expired, or in some other non-cancellable
          status). [reason] is the venue-reported status string. *)
  | Unreachable of { reason : string }
      (** {!Broker.cancel_order_by_placement_id} raised —
          transport, parse, or any other adapter-internal
          failure. *)

type handle_error = Resolution of resolution_error

val handle :
  broker:Broker.client ->
  now_ts:(unit -> int64) ->
  Cancel_pending_order_command.t ->
  (broker_outcome, handle_error) Rop.t
