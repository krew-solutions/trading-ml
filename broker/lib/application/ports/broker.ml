(** Broker abstraction — the order-routing port of the broker
    BC, expressed in our model's vocabulary only. Concrete
    integrations (Finam, BCS, Synthetic) implement [S] in their
    own library; the application talks to them through an
    existential [client] wrapper so adding a new broker is a new
    module, not a new branch in every switch.

    {b Order identity.} The only identity carried at the port
    boundary is [placement_id : int] — the cross-BC saga key
    minted by Account at reservation time and echoed through
    Submit. Venue-native handles ([client_order_id], server-side
    ids, exec ids) are concerns of each ACL adapter: every adapter
    holds its own private [placement_id ↦ native_handle] store
    (see e.g. {!Bcs.Placement_handle_store}) and never surfaces
    those handles across the port. *)

open Core

(** Unified inbound event stream from the adapter. Adapter
    encapsulates the transport (WS push, REST poll, synthetic
    generator, replay) — the same callback fires regardless of
    which path delivered the event. The caller pattern-matches
    and dispatches to the appropriate OHS publisher / consumer.

    New event kinds (Order_accepted, Order_cancelled, Order_book,
    Quote, Trade_tape, ...) are added as variants here; consumer
    pattern-matches surface exhaustivity warnings to flag
    missing handlers. *)
type event =
  | Remote_bar_updated of Remote_broker.Events.Remote_bar_updated.t
  | Order_filled of Remote_broker.Events.Order_filled.t
      (** The domain event — the adapter, acting as the
          recognizer of external venue facts (per Vernon's
          "external system as a source of Domain Events"
          pattern), constructs it directly from the broker's
          fill frame and the adapter's own per-placement
          cumulative bookkeeping. The application layer
          consumes it as-is; no further recognition step is
          needed at the seam. *)

(** Subscription request — describes what the adapter should
    listen to. The adapter is responsible for the upstream
    SUBSCRIBE / poll setup; the caller doesn't know whether the
    request lands on a multiplex socket, a dedicated socket per
    key, a polling fiber, or a synthetic generator.

    New subscription kinds (Subscribe_order_state, Subscribe_order_book,
    Subscribe_quotes, Subscribe_trade_tape, ...) are added as
    variants here. Adapters that don't support a kind log a
    diagnostic and ignore — symmetric to how unrecognised
    {!event} variants would surface as exhaustivity warnings on
    the consumer side. *)
type request = Subscribe_bars of { instrument : Instrument.t; timeframe : Timeframe.t }

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
    placement_id:int ->
    instrument:Instrument.t ->
    side:Side.t ->
    quantity:Decimal.t ->
    kind:Order.kind ->
    tif:Order.time_in_force ->
    Order.t
  (** Submit a new order under the saga's [placement_id]. The
      adapter mints whatever native handle the venue requires,
      records the linkage in its private placement-handle store,
      and returns the broker BC's internal {!Order.t} —
      ACL-private venue handles ([client_order_id], server-side
      ids, exec ids) never cross this boundary.

      The returned status is typically [New] / [Pending_new],
      but may already reflect a partial or full fill on
      aggressive orders. *)

  val cancel_order : t -> placement_id:int -> Order.t option
  (** Resolve [placement_id] to the adapter's native handle, call
      the venue's cancel, return the resulting domain {!Order.t}.
      [None] when no placement is recorded under this id (cancel
      arrived for an order this adapter never placed, or its
      index has been lost). *)

  val get_order : t -> placement_id:int -> Order.t option
  (** Snapshot of a single placement's state. [None] when no
      placement is recorded under this id. *)

  val get_trades : t -> placement_id:int -> Order.trade list
  (** Per-trade detail for a placement. Empty list when the
      order has no fills yet or no placement is recorded.
      Wire-shape projection (e.g. {!Trade_view_model.of_domain})
      happens at the external seam, not here. *)

  val start_live_feed :
    t -> sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> on_event:(event -> unit) -> unit
  (** Initialise the adapter's live event machinery. Called once
      at composition time. After this call, the adapter is ready
      to receive {!subscribe} / {!unsubscribe} requests; any
      always-on transport (Finam's multiplex socket and its
      account-wide TRADES subscription, BCS's planned personal
      WS) is opened here.

      [on_event] is invoked for every event the adapter produces,
      regardless of which internal path (WS push, REST poll,
      synthetic generator, replay) delivered it. The caller
      pattern-matches and dispatches; new event variants surface
      as exhaustivity warnings so missing handlers are caught at
      compile time. *)

  val subscribe : t -> request -> unit
  (** Register interest in a {!request}-shaped stream. Idempotent
      / refcounted on the adapter side: the first caller for a
      given key triggers the actual upstream subscription;
      subsequent callers increment an internal refcount.
      Adapters that don't support the request kind log a
      diagnostic and no-op. *)

  val unsubscribe : t -> request -> unit
  (** Decrement the internal refcount for the request's key;
      only sends the actual upstream UNSUBSCRIBE (or closes the
      per-key socket for BCS) when the count reaches zero. *)
end

type client = E : (module S with type t = 't) * 't -> client

let make (type a) (module M : S with type t = a) (x : a) : client = E ((module M), x)

let name (E ((module M), _)) = M.name

let bars (E ((module M), t)) ~n ~instrument ~timeframe =
  M.bars t ~n ~instrument ~timeframe

let venues (E ((module M), t)) = M.venues t

let place_order (E ((module M), t)) ~placement_id ~instrument ~side ~quantity ~kind ~tif =
  M.place_order t ~placement_id ~instrument ~side ~quantity ~kind ~tif

let cancel_order (E ((module M), t)) ~placement_id = M.cancel_order t ~placement_id

let get_order (E ((module M), t)) ~placement_id = M.get_order t ~placement_id

let get_trades (E ((module M), t)) ~placement_id = M.get_trades t ~placement_id

let start_live_feed (E ((module M), t)) ~sw ~env ~on_event =
  M.start_live_feed t ~sw ~env ~on_event

let subscribe (E ((module M), t)) request = M.subscribe t request

let unsubscribe (E ((module M), t)) request = M.unsubscribe t request
