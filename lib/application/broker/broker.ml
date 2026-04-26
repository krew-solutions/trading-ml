(** Broker abstraction — everything the server / engine need from a
    market data & execution provider, expressed in domain types only.
    Concrete integrations (Finam, BCS, Synthetic, Paper decorator)
    implement [S] in their own library; the server talks to them
    through an existential [client] wrapper so adding a new broker is
    a new module, not a new branch in every switch.

    Order operations use [client_order_id] as the caller-controlled
    stable handle. For BCS it coincides with the server id; for Finam
    the adapter maintains an in-memory [client_order_id → server_id]
    map so callers never see the broker's internal identity. *)

open Core

module type S = sig
  type t

  val name : string
  (** Identifier used on the CLI (e.g. "finam", "bcs") and in logs. *)

  val bars :
    t -> n:int -> instrument:Instrument.t -> timeframe:Timeframe.t -> Candle.t list
  (** Fetch the last [n] bars for [instrument] at [timeframe]. The
      adapter routes the request using whatever fields it needs:
      Finam takes [(ticker, mic)]; BCS takes [(ticker, board)] and
      ignores [mic]; both honor [board] when present (Finam falls
      back to its server-side primary-board choice when absent). *)

  val venues : t -> Mic.t list
  (** Venues this broker can route to, as ISO-10383 MIC codes.
      Human-readable labels are not the broker's responsibility — the
      UI maps known MICs to display names; unknown MICs render as the
      raw code. *)

  val place_order :
    t ->
    instrument:Instrument.t ->
    side:Side.t ->
    quantity:Decimal.t ->
    kind:Order.kind ->
    tif:Order.time_in_force ->
    client_order_id:string ->
    Order.t
  (** Submit a new order. [client_order_id] is the caller-controlled
      idempotency key; callers must guarantee uniqueness within an
      account. Returns the initial [Order.t] as reported by the broker
      (typically in [New] / [Pending_new] status). *)

  val get_orders : t -> Order.t list
  (** Snapshot of all orders in the adapter's account context. Order
      of elements is unspecified; callers sort if they care. *)

  val get_order : t -> client_order_id:string -> Order.t
  (** Fetch a single order by the client id it was created with. *)

  val cancel_order : t -> client_order_id:string -> Order.t
  (** Request cancellation. Returns the updated [Order.t]; the status
      may be [Cancelled] (confirmed) or [Pending_cancel] depending on
      the broker's response semantics. *)

  val get_executions : t -> client_order_id:string -> Order.execution list
  (** Per-execution detail for the order identified by
      [client_order_id]. Total [quantity] over the list equals the
      order's [filled]; prices are the broker's actual fill prices
      (may differ from limit/market-intended).

      Used by {!Live_engine.reconcile} to commit a reservation with
      real numbers when a {!Order.Filled} status is observed via
      polling (the primary WS-event path already carries actuals).
      Returning an empty list is a valid response for adapters that
      don't (yet) surface per-execution detail — callers must fall
      back to intended numbers in that case. *)

  val generate_client_order_id : t -> string
  (** Produce a fresh [client_order_id] in whatever format this
      broker's wire validator accepts. Examples from real broker
      validators we've hit: BCS requires dashed UUID ("UUID" format),
      Finam accepts "letters, numbers and space" only and rejects
      dashes. Owning the format inside the adapter keeps the engine
      broker-agnostic — no ["finam" | "bcs"] branches upstream — and
      lets us round-trip the same exact string through the broker's
      [place_order] → [get_order] path without a wire↔engine id map. *)
end

type client = E : (module S with type t = 't) * 't -> client

let make (type a) (module M : S with type t = a) (x : a) : client = E ((module M), x)

let name (E ((module M), _)) = M.name

let bars (E ((module M), t)) ~n ~instrument ~timeframe =
  M.bars t ~n ~instrument ~timeframe

let venues (E ((module M), t)) = M.venues t

let place_order
    (E ((module M), t))
    ~instrument
    ~side
    ~quantity
    ~kind
    ~tif
    ~client_order_id =
  M.place_order t ~instrument ~side ~quantity ~kind ~tif ~client_order_id

let get_orders (E ((module M), t)) = M.get_orders t

let get_order (E ((module M), t)) ~client_order_id = M.get_order t ~client_order_id

let cancel_order (E ((module M), t)) ~client_order_id = M.cancel_order t ~client_order_id

let get_executions (E ((module M), t)) ~client_order_id =
  M.get_executions t ~client_order_id

let generate_client_order_id (E ((module M), t)) = M.generate_client_order_id t
