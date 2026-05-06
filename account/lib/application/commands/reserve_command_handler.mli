(** Command handler for {!Reserve_command.t}.

    Accepts the wire-format command directly and is responsible
    for the entire reservation step: parse, invariant check via
    {!Account.Portfolio.try_reserve}, mutation of the shared
    portfolio ref, and emission of the resulting domain event.

    Validation is intentionally a private internal phase, not a
    separately exposed step: a CQRS command is bound to exactly
    one handler in exactly one workflow, and after parse there is
    no further pipeline stage to compose with — Wlaschin's
    [validateOrder >=> priceOrder >=> ...] split applies when the
    workflow has multiple business steps; ours has one.
    Domain-event handlers, by contrast, are exported because
    {!Account.Portfolio.Events.Amount_reserved.t} can have
    multiple subscribers (DIP). Commands lack that property. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Invalid_quantity_format of string
  | Non_positive_quantity of string
  | Invalid_price_format of string
  | Non_positive_price of string

val validation_error_to_string : validation_error -> string

val reservation_error_to_string : Account.Portfolio.reservation_error -> string
(** Application-layer projection of the domain
    {!Account.Portfolio.reservation_error} into a free-form
    [reason] string suitable for the [Reservation_rejected]
    integration event. *)

(** {1 Validated form} *)

type validated_reserve_command = {
  side : Core.Side.t;
  instrument : Core.Instrument.t;
  quantity : Decimal.t;
  price : Decimal.t;
}
(** Post-parse intermediate form. Wlaschin's [ValidatedX]:
    syntax has been parsed into domain types, but the
    {!Account.Portfolio} invariants (sufficient cash, sufficient
    margin) have not yet been checked. Surfaced on the
    {!Reservation} failure track so the workflow can populate
    the rejection integration event with attempt context. *)

(** {1 Outcome} *)

type handle_error =
  | Validation of validation_error
  | Reservation of {
      attempted : validated_reserve_command;
      error : Account.Portfolio.reservation_error;
    }
      (** Distinguishes a contract-violating caller (malformed
        wire format, never reached the aggregate) from a
        legitimate business rejection (well-formed attempt,
        invariant said no). The workflow uses the discriminator
        to decide whether to publish a
        {!Reservation_rejected_integration_event.t}. *)

val handle :
  portfolio:Account.Portfolio.t ref ->
  next_reservation_id:(unit -> int) ->
  slippage_buffer:Decimal.t ->
  fee_rate:Decimal.t ->
  margin_policy:Account.Portfolio.Margin_policy.t ->
  mark:(Core.Instrument.t -> Decimal.t option) ->
  Reserve_command.t ->
  (Account.Portfolio.Events.Amount_reserved.t, handle_error) Rop.t
(** Parse the wire-format command, attempt the reservation
    on the shared portfolio ref, and on success mutate it and
    yield the resulting domain event. Does not publish any
    integration event — that is the
    {!Reserve_command_workflow.execute} pipeline's job. *)
