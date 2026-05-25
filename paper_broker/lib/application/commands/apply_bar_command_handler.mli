(** Command handler for {!Apply_bar_command.t}.

    Wire-format primitives are parsed back into a domain
    {!Core.Candle.t}, then every active {!Paper_broker.Order.t} on
    the bar's instrument is tested against the matching rules.
    Orders that match are atomically updated in the
    {!Paper_broker_store.Order_store.S} via
    {!Paper_broker_store.Order_store.S.update}; resulting
    {!Paper_broker.Order.Events.Trade_executed.t} domain events are
    returned for the enclosing workflow to translate into outbound
    integration events.

    No partial-fill participation cap is applied when
    [participation_rate = None]. With [Some rate], a single fill is
    capped at [bar.volume * rate]. *)

(** {1 Validation errors} *)

type validation_error =
  | Invalid_instrument of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_ts of string
  | Invalid_candle of string

val validation_error_to_string : validation_error -> string

(** {1 Outcome} *)

type handle_error = Validation of validation_error

type fill_outcome = {
  order : Paper_broker.Order.t;
  event : Paper_broker.Order.Events.Trade_executed.t;
}
(** Per-order fill: the post-fill {!Paper_broker.Order.t} (reflecting
    new [filled]/[status]) plus the corresponding domain event. *)

module type Store = Paper_broker_store.Order_store.S

val handle :
  store:(module Store with type t = 'store) ->
  store_handle:'store ->
  slippage_bps:Paper_broker.Slippage.Values.Slippage_bps.t ->
  fee_rate:Paper_broker.Fee.Values.Fee_rate.t ->
  participation_rate:Paper_broker.Matching.Values.Participation_rate.t option ->
  next_trade_id:(unit -> string) ->
  Apply_bar_command.t ->
  (fill_outcome list, handle_error) Rop.t
