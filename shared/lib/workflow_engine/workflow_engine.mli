(** Workflow engine — runtime for long-running, message-driven
    processes.

    Implements the **Process Manager** pattern from Hohpe & Woolf,
    *Enterprise Integration Patterns* (Addison-Wesley, 2003), ch. 11:
    a central component that "maintains the state of the sequence
    and determines the next processing step based on intermediate
    results". Each running process is an independent **instance**
    keyed by a [correlation_id] carried in every inbound event;
    the engine multiplexes any number of such instances of one
    workflow definition.

    The design separates four concerns:
    - {b Definition} — pure state machine ({!WORKFLOW}): how state
      reacts to events, what commands result, what counts as
      terminal. No I/O, no side effects, easy to unit-test.
    - {b Persistence} — abstracted behind {!Store.S}; the engine
      reads, atomically updates, and deletes instance state via
      this port. The default {!In_memory_store} is shipped; a
      persistent backend (Postgres, Redis) can be plugged in
      without touching workflow definitions.
    - {b Wiring} — composition root subscribes its event buses
      to {!Make.on_event} and supplies a [dispatch] callback that
      routes commands to the right command bus. The engine itself
      does not know about specific buses.
    - {b Lifecycle} — engine creates instances on {!Make.start},
      drops them when {!WORKFLOW.is_terminal} fires, silently
      ignores events for unknown correlation_ids (idempotent
      delivery contract). *)

module Store = Store
module In_memory_store = In_memory_store

(** Definition of a single workflow. A composing module supplies
    the state, event, and command types and the pure transition
    function; the engine ({!Make}) provides the runtime. *)
module type WORKFLOW = sig
  type state
  (** Per-instance state. Opaque to the engine between transitions. *)

  type event
  (** Discriminated union of every event the workflow reacts to.
      Typically one constructor per integration event the
      composing module subscribes to. *)

  type command
  (** Discriminated union of every command the workflow may
      dispatch. The engine hands these to the [dispatch] callback
      configured at engine creation. *)

  val name : string
  (** Diagnostic label — appears in logs. Same name across all
      instances of the same workflow definition. *)

  val correlation_of_event : event -> string
  (** Extract the correlation_id from an inbound event. Each event
      type the workflow reacts to MUST carry one — the contract
      between the engine and the BCs feeding it. *)

  val transition : state -> event -> state * command list
  (** Pure step. Given current state and inbound event, return
      next state and any commands to dispatch. The engine
      persists the state and dispatches the commands; the
      function itself must not have side effects. *)

  val is_terminal : state -> bool
  (** No outgoing transitions from this state. The engine drops
      terminal instances after the transition. *)
end

(** Engine instantiated for one workflow definition over one
    storage backend. *)
module Make (W : WORKFLOW) (S : Store.S) : sig
  type t

  val create : store:W.state S.t -> dispatch:(W.command -> unit) -> t
  (** [store] is a fresh handle owned by this engine.
      [dispatch] is invoked synchronously, once per command,
      from {!on_event} after the state has been persisted. *)

  val start : t -> correlation_id:string -> W.state -> unit
  (** Register a new workflow instance with its initial state.
      Raises [Invalid_argument] if [correlation_id] is already
      tracked — the caller is responsible for collision-free
      ids (UUID v4 suffices in practice). *)

  val on_event : t -> W.event -> unit
  (** Apply an event:

      {ol
      {- Look up the instance by [W.correlation_of_event ev].}
      {- If absent, log at debug and return — events for
         unknown / already-completed instances are silently
         dropped (the idempotency contract).}
      {- Otherwise call [W.transition] inside the store's
         atomic update, persist the new state (or remove the
         entry if {!WORKFLOW.is_terminal}), then dispatch each
         resulting command via [dispatch].}
      }

      Persistence and dispatch are split across the store-update
      boundary so [dispatch] re-entering {!on_event} from the
      same fiber doesn't deadlock — by the time dispatch runs,
      the state mutation is already committed. *)

  val get : t -> correlation_id:string -> W.state option
  (** Snapshot of one instance's current state. Diagnostics and
      SSE projections; [None] for unknown / completed. *)

  val active_count : t -> int
  (** Snapshot count of non-terminal instances. *)
end
