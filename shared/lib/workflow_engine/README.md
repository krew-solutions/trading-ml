# workflow_engine

Runtime for long-running, message-driven processes — implementation
of the **Process Manager** pattern from Hohpe & Woolf,
*Enterprise Integration Patterns* (Addison-Wesley, 2003), ch. 11.

API contract is documented in [`workflow_engine.mli`](workflow_engine.mli);
the persistence port in [`store.mli`](store.mli); the default
single-process backend in [`in_memory_store.mli`](in_memory_store.mli).

This README walks through what a real saga looks like on top of the
engine, using the place-order flow (Account reserves cash → Broker
submits order → optional compensation) as the worked example.

## Engine surface, in three lines

```ocaml
module Engine = Workflow_engine.Make (My_workflow) (Workflow_engine.In_memory_store)
let store  = Workflow_engine.In_memory_store.create ()
let engine = Engine.create ~store ~dispatch:(fun cmd -> ...)
```

The composing module supplies a `WORKFLOW` definition (state, event,
command types and a pure `transition` function); the engine handles
persistence and dispatch. Events are fed in via `Engine.on_event`;
new instances are opened with `Engine.start`.

---

## Worked example: place-order saga

The saga coordinates two bounded contexts:

- **Account** — owns the cash/positions ledger; reserves funds before
  an order is sent, releases on rejection.
- **Broker** — talks to the upstream venue (Finam / BCS / paper);
  emits accepted/rejected/unreachable events.

Five paths through the state machine: one happy, four compensation.

### 1. Workflow definition (pure state machine)

```ocaml
(* process_managers/place_order/place_order_pm.ml *)

open Core

module Definition = struct
  (** Original request payload, captured at HTTP entry and stashed
      in the saga store under the correlation_id — broker-specific
      fields (kind/tif) live here, not in the integration events,
      so the events stay business-fact shaped. *)
  type payload = {
    instrument : Instrument.t;
    side : Side.t;
    quantity : Decimal.t;
    kind : Order.kind;
    tif : Order.time_in_force;
  }

  type state =
    | Awaiting_reservation of { payload : payload }
    | Submitted of { payload : payload; reservation_id : int }
    | Done of { reservation_id : int }
    | Compensated of { reason : string }

  (** Each event MUST carry the correlation_id of its saga
      instance — that's the contract between the engine and the
      BCs feeding it. *)
  type event =
    | Amount_reserved of
        Account_integration_events.Amount_reserved_integration_event.t
    | Reservation_rejected of
        Account_integration_events.Reservation_rejected_integration_event.t
    | Order_accepted of
        Broker_integration_events.Order_accepted_integration_event.t
    | Order_rejected of
        Broker_integration_events.Order_rejected_integration_event.t
    | Order_unreachable of
        Broker_integration_events.Order_unreachable_integration_event.t

  type status_event =
    | Reservation_accepted of int
    | Placed of Queries.Order_view_model.t
    | Rejected_by_account of string
    | Rejected_by_broker of string
    | Broker_unreachable of string

  type command =
    | Submit of Broker_commands.Submit_order_command.t
    | Release of Account_commands.Release_command.t
    | Publish_status of { correlation_id : string; status : status_event }

  let name = "place_order"

  let correlation_of_event = function
    | Amount_reserved e -> e.correlation_id
    | Reservation_rejected e -> e.correlation_id
    | Order_accepted e -> e.correlation_id
    | Order_rejected e -> e.correlation_id
    | Order_unreachable e -> e.correlation_id

  let to_submit_command ~payload ~reservation_id ~correlation_id =
    Broker_commands.Submit_order_command.{
      reservation_id;
      correlation_id;
      symbol = Instrument.to_qualified payload.instrument;
      side = Side.to_string payload.side;
      quantity = Decimal.to_string payload.quantity;
      kind = Queries.Order_kind_view_model.of_domain payload.kind;
      tif = Order.tif_to_string payload.tif;
    }

  let transition state event =
    match state, event with
    (* Happy path: Account reserved → dispatch Submit *)
    | Awaiting_reservation { payload }, Amount_reserved ev ->
        let submit =
          to_submit_command ~payload ~reservation_id:ev.reservation_id
            ~correlation_id:ev.correlation_id
        in
        Submitted { payload; reservation_id = ev.reservation_id },
        [ Submit submit;
          Publish_status { correlation_id = ev.correlation_id;
                           status = Reservation_accepted ev.reservation_id } ]

    (* Account refused — nothing to compensate, never reserved *)
    | Awaiting_reservation _, Reservation_rejected ev ->
        Compensated { reason = "rejected_by_account: " ^ ev.reason },
        [ Publish_status { correlation_id = ev.correlation_id;
                           status = Rejected_by_account ev.reason } ]

    (* Broker accepted → done *)
    | Submitted { reservation_id; _ }, Order_accepted ev ->
        Done { reservation_id },
        [ Publish_status { correlation_id = ev.correlation_id;
                           status = Placed ev.broker_order } ]

    (* Broker rejected → release reservation *)
    | Submitted { reservation_id; _ }, Order_rejected ev ->
        Compensated { reason = "rejected_by_broker: " ^ ev.reason },
        [ Release { reservation_id };
          Publish_status { correlation_id = ev.correlation_id;
                           status = Rejected_by_broker ev.reason } ]

    (* Broker unreachable → release as well; reconcile handles
       any orphan order created on the venue side *)
    | Submitted { reservation_id; _ }, Order_unreachable ev ->
        Compensated { reason = "broker_unreachable: " ^ ev.reason },
        [ Release { reservation_id };
          Publish_status { correlation_id = ev.correlation_id;
                           status = Broker_unreachable ev.reason } ]

    (* Idempotent fall-through: a duplicate / late event arriving
       at a state the saga has already moved past is a no-op. *)
    | (Done _ | Compensated _), _
    | Submitted _, (Amount_reserved _ | Reservation_rejected _)
    | Awaiting_reservation _,
      (Order_accepted _ | Order_rejected _ | Order_unreachable _) ->
        state, []

  let is_terminal = function
    | Done _ | Compensated _ -> true
    | Awaiting_reservation _ | Submitted _ -> false
end
```

`transition` is a pure function — no buses, no HTTP, no Eio — and is
unit-tested with plain OCaml values. Five transition cases plus one
fall-through cover the entire state machine.

### 2. Composition root: wiring buses to the engine

```ocaml
(* bin/main.ml *)

module Engine =
  Workflow_engine.Make (Place_order_pm.Definition) (Workflow_engine.In_memory_store)

let setup_place_order_saga
    ~submit_bus ~release_bus
    ~events_amount_reserved ~events_reservation_rejected
    ~events_order_accepted ~events_order_rejected ~events_order_unreachable
    ~publish_status_sse =
  let store = Workflow_engine.In_memory_store.create () in
  let dispatch = function
    | Place_order_pm.Definition.Submit cmd ->
        Bus.Command_bus.send submit_bus cmd
    | Release cmd ->
        Bus.Command_bus.send release_bus cmd
    | Publish_status { correlation_id; status } ->
        publish_status_sse ~correlation_id status
  in
  let engine = Engine.create ~store ~dispatch in
  (* Bridge typed event buses into the engine's event union.
     This is the only boilerplate the composition root pays. *)
  let _ = Bus.Event_bus.subscribe events_amount_reserved
    (fun e -> Engine.on_event engine (Amount_reserved e)) in
  let _ = Bus.Event_bus.subscribe events_reservation_rejected
    (fun e -> Engine.on_event engine (Reservation_rejected e)) in
  let _ = Bus.Event_bus.subscribe events_order_accepted
    (fun e -> Engine.on_event engine (Order_accepted e)) in
  let _ = Bus.Event_bus.subscribe events_order_rejected
    (fun e -> Engine.on_event engine (Order_rejected e)) in
  let _ = Bus.Event_bus.subscribe events_order_unreachable
    (fun e -> Engine.on_event engine (Order_unreachable e)) in
  engine
```

### 3. HTTP entry: opening a saga instance

```ocaml
(* account/lib/infrastructure/inbound/http/http.ml *)

let make_handler ~reserve_bus ~saga_engine ~gen_correlation_id ~market_price =
 fun request body ->
  match meth, path with
  | `POST, "/api/orders" ->
      let body_str = Eio.Flow.read_all body in
      let req = place_order_of_json (Yojson.Safe.from_string body_str) in
      let correlation_id = gen_correlation_id () in   (* UUID v4 *)
      (* 1. Open the saga instance with the original payload *)
      Engine.start saga_engine ~correlation_id
        (Place_order_pm.Definition.Awaiting_reservation { payload = {
          instrument = req.instrument; side = req.side;
          quantity = req.quantity; kind = req.kind; tif = req.tif } });
      (* 2. Dispatch Reserve_command, threading correlation_id *)
      Bus.Command_bus.send reserve_bus
        (to_reserve_command market_price req ~correlation_id);
      (* 3. Return 202 with correlation_id; the client tracks
            saga progress over the SSE channel *)
      Some (202, `Response
        (Inbound_http.Response.json ~status:`Accepted
          (`Assoc [
            ("status", `String "accepted");
            ("correlation_id", `String correlation_id);
          ])))
  | _ -> None
```

### 4. Tests against the pure transition

```ocaml
(* test/unit/process_managers/place_order_pm_test.ml *)

let cid = "01HX-TEST"
let payload = { instrument = ...; side = Buy; quantity = d 10; ... }

let test_amount_reserved_submits_and_publishes () =
  let s = Awaiting_reservation { payload } in
  let s', cmds = Place_order_pm.Definition.transition s
    (Amount_reserved { reservation_id = 42; correlation_id = cid; ... })
  in
  Alcotest.(check ...) "state moved to submitted"
    (Submitted { payload; reservation_id = 42 }) s';
  Alcotest.(check int) "two commands" 2 (List.length cmds)
  (* + assertions on command contents *)

let test_order_rejected_releases_reservation () =
  let s = Submitted { payload; reservation_id = 42 } in
  let s', cmds = Place_order_pm.Definition.transition s
    (Order_rejected { reservation_id = 42; correlation_id = cid;
                      reason = "no liquidity" })
  in
  Alcotest.(check ...) "state compensated" (Compensated _) s';
  match cmds with
  | [ Release { reservation_id = 42 }; Publish_status _ ] -> ()
  | _ -> Alcotest.fail "expected Release + Publish_status"

(* Idempotency: a late duplicate event is a no-op *)
let test_late_amount_reserved_in_submitted_is_noop () =
  let s = Submitted { payload; reservation_id = 42 } in
  let s', cmds = Place_order_pm.Definition.transition s
    (Amount_reserved { reservation_id = 42; correlation_id = cid; ... })
  in
  Alcotest.(check ...) "state unchanged" s s';
  Alcotest.(check int) "no commands" 0 (List.length cmds)
```

---

## What this design buys

1. **Workflow definition is concern-free.** No buses, no HTTP, no
   concurrency primitives — just state, event union, command union,
   and a pure transition. Unit-tested as plain values.
2. **Business logic for all five paths (happy + four compensations)
   is one function.** A single `match` makes every path explicit;
   nothing is hidden in handler chains.
3. **Idempotency is a pattern-match concern.** Late or duplicate
   events for already-advanced state return `(state, [])`; the
   engine additionally drops events for unknown correlation_ids.
4. **Bus wiring is one place** — `setup_place_order_saga` in the
   composition root, five subscription lines. Everything else is
   pure code.
5. **HTTP entry shrinks to mechanical.** `Engine.start` +
   `Bus.Command_bus.send` + 202. No "what to do after Reserve",
   no "how to wait for the broker", no "how to compensate" — all of
   that is in the transition function.

---

## Prerequisites for the example to compile

The sketch above assumes a few changes that are **not yet** in the
codebase:

| Change | Files |
|---|---|
| Add `correlation_id : string` to seven DTOs | `Reserve_command`, `Amount_reserved_int_ev`, `Reservation_rejected_int_ev`, `Submit_order_command`, `Order_accepted_int_ev`, `Order_rejected_int_ev`, `Order_unreachable_int_ev` (plus the workflows that thread them through) |
| UUID v4 generator | New `shared/lib/correlation_id` or use the existing `uuidm` opam package |
| SSE channel `saga` | `lib/infrastructure/inbound/http/publish_*.ml` |
| Decouple the synchronous `reserve` from HTTP | `account/lib/infrastructure/inbound/http/http.ml` |

The engine itself is ready to host the saga as soon as the DTO
correlation_id refactor lands.

## Where the engine intentionally stops

The engine is small on purpose. Out-of-scope concerns and the
shape of their future fix:

- **Durable execution across restarts** — implement
  [`Store.S`](store.mli) over Postgres or Redis; engine code stays
  the same.
- **TTL / GC for stuck non-terminal sagas** — a fiber periodically
  enumerates the store, flips long-`Awaiting_X` instances to
  `Compensated { reason = "timeout" }`, and emits any compensating
  commands.
- **Distributed coordination across multiple engine processes** —
  outside the current single-handle ACID contract; needs idempotency
  keys at the bus level and a backend with cross-process locking.
- **Visibility / replay UI** — the audit trail is already provided
  by the integration-event bus; a UI on top is a separate concern.
