module Values : module type of Values
module Events : module type of Events

(** Working order inside paper_broker — Entity with identity
    [client_order_id] and a status lifecycle controlled by
    {!apply_fill} / {!cancel}. Immutable: every transition returns
    a fresh aggregate plus the matching domain event.

    Invariants:
    - [quantity > 0];
    - [0 <= filled <= quantity];
    - [filled = quantity] iff [status = Filled];
    - terminal statuses cannot transition any further. *)

type t = private {
  id : string;
  client_order_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
  kind : Values.Order_kind.t;
  tif : Values.Time_in_force.t;
  status : Values.Order_status.t;
  created_ts : int64;
  placed_after_ts : int64;
}

val remaining : t -> Decimal.t
(** [quantity - filled]. *)

val is_terminal : t -> bool
(** [Values.Order_status.is_terminal status]. *)

val make :
  id:string ->
  client_order_id:string ->
  instrument:Core.Instrument.t ->
  side:Core.Side.t ->
  quantity:Decimal.t ->
  kind:Values.Order_kind.t ->
  tif:Values.Time_in_force.t ->
  created_ts:int64 ->
  placed_after_ts:int64 ->
  t * Events.Order_accepted.t
(** Creates a fresh order in [New] status. Raises [Invalid_argument]
    on [quantity <= 0], [created_ts < 0], or [placed_after_ts < 0]. *)

type apply_fill_error =
  | Order_already_terminal of Values.Order_status.t
  | Overfill of { remaining : Decimal.t; attempted : Decimal.t }
  | Non_positive_fill_quantity of Decimal.t
  | Negative_fee of Decimal.t

val apply_fill :
  t ->
  exec_id:string ->
  fill_quantity:Decimal.t ->
  fill_price:Decimal.t ->
  fee:Decimal.t ->
  fill_ts:int64 ->
  (t * Events.Fill_observed.t, apply_fill_error) result
(** Applies a partial or full fill. The new status is
    [Partially_filled] when filled total is below [quantity], else
    [Filled]. *)

type cancel_error = Order_already_terminal of Values.Order_status.t

val cancel : t -> cancelled_ts:int64 -> (t * Events.Order_cancelled.t, cancel_error) result
(** Transitions a working order to [Cancelled]. Fails when the
    order is already in a terminal status. *)
