(** Order model — broker BC's abstraction over the function it
    executes (order routing to a venue). The vocabulary and
    invariants are uniform across all concrete venues; protocol
    specifics live below the ACL boundary. See ADR-0015. *)

type kind =
  | Market
  | Limit of Decimal.t
  | Stop of Decimal.t
  | Stop_limit of { stop : Decimal.t; limit : Decimal.t }

type time_in_force = GTC | DAY | IOC | FOK

type status =
  | New
  | Partially_filled
  | Filled
  | Cancelled
  | Rejected
  | Expired
  | Pending_cancel
  | Pending_new
  | Suspended
  | Failed

type t = {
  placement_id : int;
      (** Cross-BC saga key — the only identity carried in our
          model. Venue-native handles ([client_order_id],
          server-side ids, exec ids) live privately inside each
          ACL adapter and never reach this type. *)
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  filled : Decimal.t;
      (** Invariant: [0 ≤ filled ≤ quantity]. [remaining] is
          derived via {!remaining_qty}. *)
  kind : kind;
  tif : time_in_force;
  status : status;
  placed_ts : int64;
      (** Domain-event timestamp — int64 epoch, the moment the
          venue reports as the placement's acceptance time. The
          authoritative source is the venue (it is its event,
          not ours); the ACL adapter normalises whatever
          incompatible shape the venue uses (ISO-8601, vendor
          epoch, RFC 3339, etc.) into our int64 form. *)
}

type execution = { ts : int64; quantity : Decimal.t; price : Decimal.t; fee : Decimal.t }
(** One execution (trade / fill slice) observed at the venue.
    A single {!t} may be filled across multiple executions;
    the sum of [quantity] over the list equals the order's
    [filled]. Price and fee are venue-actual numbers per fill
    (not intended). [ts] is the venue-reported fill timestamp
    normalised to int64 epoch. *)

val remaining_qty : t -> Decimal.t
(** [quantity - filled]. Non-negative by the [filled ≤ quantity]
    invariant (formally verified — see [order.mlw]). *)

val is_done : t -> bool
(** True for terminal statuses ([Filled] / [Cancelled] /
    [Rejected] / [Expired] / [Failed]) — no further state change
    is expected. *)

val kind_to_string : kind -> string
val status_to_string : status -> string
val tif_to_string : time_in_force -> string
