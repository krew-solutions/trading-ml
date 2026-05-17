(** OrderTicket — the EMS-layer aggregate that owns a trader's
    execution intent through its slicing lifecycle.

    One ticket ⇔ one cash reservation (the OMS-layer saga
    [Open_order_ticket_process] hands off on [Amount_reserved]).
    The embedded {!Strategies.Strategy.t} decides HOW to slice the
    intent into broker-bound placements; the aggregate enforces
    the global invariants:

    - [Σ Placement.cumulative_filled ≤ Trade_intent.total_quantity];
    - terminal states are absorbing (late inputs become noops);
    - no submits / cancels in terminal lifecycle states;
    - the strategy proposes, the aggregate disposes — every
      [Decision.submit_request] becomes a [Placement] only after
      passing the aggregate's invariant checks.

    Lifecycle: [Working] → ({Filled | Cancelling → {Filled |
    Cancelled} | Failed}). [Filled] / [Cancelled] / [Failed] are
    terminal. *)

module Values : module type of Values
module Placement : module type of Placement
module Events : module type of Events
module Strategies : module type of Strategies

(*@ function dec_raw (d : Decimal.t) : integer *)

type t

(** Lifecycle phase. Exposed for inspection (queries, tests);
    state transitions are driven only through the operations below. *)
type lifecycle =
  | Working of Strategies.Strategy.t
  | Cancelling of {
      strategy : Strategies.Strategy.t;
      reason : Values.Cancel_reason.t;
    }
  | Filled
  | Cancelled of Values.Cancel_reason.t
  | Failed of string

(** Uniform event envelope: each operation returns a list of
    these in the order they were produced, so the application
    layer can publish without caring which operation made them. *)
type event =
  | Ev_ticket_opened of Events.Ticket_opened.t
  | Ev_placement_dispatched of Events.Placement_dispatched.t
  | Ev_placement_acknowledged of Events.Placement_acknowledged.t
  | Ev_placement_filled of Events.Placement_filled.t
  | Ev_placement_rejected of Events.Placement_rejected.t
  | Ev_placement_unreachable of Events.Placement_unreachable.t
  | Ev_placement_cancelled of Events.Placement_cancelled.t
  | Ev_ticket_cancelling_started of Events.Ticket_cancelling_started.t
  | Ev_ticket_completed of Events.Ticket_completed.t
  | Ev_ticket_cancelled of Events.Ticket_cancelled.t
  | Ev_ticket_failed of Events.Ticket_failed.t

(** Inspection. *)
val ticket_id : t -> Values.Ticket_id.t
val intent : t -> Values.Trade_intent.t
val directive : t -> Values.Execution_directive.t
val lifecycle : t -> lifecycle
val progress : t -> Values.Progress.t
val placements : t -> Placement.t list
val find_placement : t -> Placement.Values.Placement_id.t -> Placement.t option
val is_terminal : t -> bool

(** Operations. Each takes [now] for ADR-0013 clock injection. *)

val open_ticket :
  ticket_id:Values.Ticket_id.t ->
  intent:Values.Trade_intent.t ->
  directive:Values.Execution_directive.t ->
  now:int64 ->
  t * event list
(** Open a new ticket, run [Strategy.init], materialise any
    initial submits the strategy proposes, and return the
    aggregate paired with [Ev_ticket_opened] followed by the
    [Ev_placement_dispatched] events. *)

val on_placement_acknowledged :
  t -> placement_id:Placement.Values.Placement_id.t -> now:int64 -> t * event list

val on_placement_fill :
  t ->
  placement_id:Placement.Values.Placement_id.t ->
  fill:Placement.Values.Fill_record.t ->
  now:int64 ->
  t * event list

val on_placement_rejection :
  t ->
  placement_id:Placement.Values.Placement_id.t ->
  reason:string ->
  now:int64 ->
  t * event list

val on_placement_unreachable :
  t -> placement_id:Placement.Values.Placement_id.t -> now:int64 -> t * event list

val on_placement_cancelled :
  t -> placement_id:Placement.Values.Placement_id.t -> now:int64 -> t * event list

val on_clock_tick : t -> now:int64 -> t * event list
(** Forward a clock tick to the strategy; materialise any
    additional submits the strategy proposes (TWAP / VWAP / IS
    typically emit on ticks). No-op in terminal lifecycle states. *)

val on_volume_bar :
  t -> bar:Values.Volume_bar.t -> now:int64 -> t * event list
(** Forward a volume bar to the strategy (POV consumes these).
    No-op in terminal lifecycle states. *)

val cancel :
  t -> reason:Values.Cancel_reason.t -> now:int64 -> t * event list
(** Operator-initiated cancel. Transitions [Working → Cancelling];
    emits [Ev_ticket_cancelling_started] carrying the
    outstanding placement_ids the application layer must
    dispatch broker-side cancels for. No-op when already
    [Cancelling] or terminal. *)
