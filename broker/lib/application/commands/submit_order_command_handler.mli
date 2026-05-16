(** Command handler for {!Submit_order_command.t}.

    Two phases in one Rop pipeline:

    - {b Validate}: parse the wire-format primitives back into
      domain values (instrument, side, decimal quantity, kind
      variant, tif) via parallel applicative branches. Multiple
      bad fields surface as a non-empty error list in one pass.
    - {b Place}: on validation success, call the injected
      {!Broker.client}'s [place_order], wrapping any transport
      exception. The outcome is a tri-state {!broker_outcome}:
      [Accepted] / [Rejected] (venue refused) / [Unreachable]
      (transport / adapter raised).

    Publishing the corresponding integration event and projecting
    the [Order.t] into the wire view model is the enclosing
    {!Submit_order_command_workflow.execute} pipeline's job. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Invalid_kind of string
  | Invalid_kind_price_format of { field : string; value : string }
  | Missing_kind_price of { kind : string; field : string }
  | Invalid_tif of string

val validation_error_to_string : validation_error -> string

(** {1 Validated form} *)

type validated_submit_order_command = {
  correlation_id : string;
  placement_id : int;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  kind : Order.kind;
  tif : Order.time_in_force;
}
(** Post-parse intermediate form: wire primitives lifted into
    domain values; the upstream broker has not yet been
    contacted. *)

(** {1 Outcome} *)

type broker_outcome =
  | Accepted of Order.t
  | Rejected of { order : Order.t; reason : string }
  | Unreachable of { reason : string }
(** Tri-state result of the [Broker.place_order] call. [Accepted]
    when the broker returned an order with any non-[Rejected]
    status; [Rejected] when it returned [status = Rejected]
    (venue refusal); [Unreachable] when the adapter raised
    (transport, parse, anything else). *)

type handle_error = Validation of validation_error

val handle :
  broker:Broker.client ->
  Submit_order_command.t ->
  (broker_outcome, handle_error) Rop.t
(** Validate the command, and on success contact the broker.
    Returns the [broker_outcome] on success or an accumulated
    list of validation errors. *)
