(** Command: place a new order. Inbound driving port — received
    via HTTP from external actors (UI, curl, other services).
    Not the path automated strategies use; those go straight
    through the outbound {!Broker.place_order} port without
    passing through this command. *)

open Core

type t = {
  symbol : string;
  side : string;
  quantity : float;
  kind : Queries.Order_kind_view_model.t;
  tif : string;
  client_order_id : string;
}
[@@deriving yojson]
(** Command payload — straight from HTTP body, primitive-typed,
    unvalidated. [kind] reuses the view model so the JSON shape
    of the [kind] subtree matches the outbound form. *)

type validation_error =
  | Invalid_symbol of string
  | Invalid_side of string
  | Non_positive_quantity of float
  | Unknown_kind_type of string
  | Missing_kind_price of { kind_type : string; field : string }
  | Invalid_tif of string
  | Missing_client_order_id

val validation_error_to_string : validation_error -> string

type unvalidated = {
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  kind : Order.kind;
  tif : Order.time_in_force;
  client_order_id : string;
}
(** Post-parse, pre-dispatch intermediate form: primitives
    mapped into domain types, but not yet sent to the broker.
    Every field that reaches this stage is syntactically valid —
    semantic rejection (insufficient funds, instrument not
    tradable) is the broker's concern and surfaces at
    {!execute}. *)

val to_unvalidated : t -> (unvalidated, validation_error) Rop.t
(** Parse + translate all fields into domain types. Accumulates
    errors rather than short-circuiting: a caller submitting
    bad symbol AND bad side AND negative quantity sees all three
    problems in one response, not one-per-round-trip. *)

(** {1 Step 1: reserve funds / securities on local portfolio}

    Thin application-level handler over
    {!Engine.Portfolio.try_reserve}: the reservation invariant
    and the event {!Engine.Portfolio.amount_reserved} live in
    the domain aggregate; this step just threads the command's
    configuration (market price, slippage buffer, fee rate) and
    generates the reservation id. *)

val reservation_error_to_string : Engine.Portfolio.reservation_error -> string

val reserve :
  portfolio:Engine.Portfolio.t ->
  market_price:Decimal.t ->
  slippage_buffer:float ->
  fee_rate:float ->
  next_reservation_id:(unit -> int) ->
  unvalidated ->
  ( Engine.Portfolio.t * Engine.Portfolio.amount_reserved,
    Engine.Portfolio.reservation_error )
  Rop.t
