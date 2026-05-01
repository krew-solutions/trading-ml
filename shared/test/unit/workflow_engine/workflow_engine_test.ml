(** Unit tests for {!Workflow_engine}. The fixture is a minimal
    request/response saga: state counts inbound [Ping]s, every
    one emits a [Pong] command; an explicit [Stop] event drives
    the state machine to its terminal state, exercising the
    instance-cleanup path. *)

module Sample = struct
  type state = { count : int; stopped : bool }
  type event = Ping of { cid : string } | Stop of { cid : string }
  type command = Pong of { cid : string; n : int }

  let name = "sample"

  let correlation_of_event = function
    | Ping { cid } | Stop { cid } -> cid

  let transition s = function
    | Ping { cid } ->
        let s' = { s with count = s.count + 1 } in
        (s', [ Pong { cid; n = s'.count } ])
    | Stop _ -> ({ s with stopped = true }, [])

  let is_terminal s = s.stopped
end

module Engine = Workflow_engine.Make (Sample) (Workflow_engine.In_memory_store)

let cid_a = "saga-A"
let cid_b = "saga-B"

let collect_dispatch () =
  let ref_ = ref [] in
  let dispatch cmd = ref_ := cmd :: !ref_ in
  let snapshot () = List.rev !ref_ in
  (dispatch, snapshot)

let make_engine ~dispatch =
  let store = Workflow_engine.In_memory_store.create () in
  Engine.create ~store ~dispatch

let test_start_then_event_transitions_state () =
  let dispatch, snapshot = collect_dispatch () in
  let engine = make_engine ~dispatch in
  Engine.start engine ~correlation_id:cid_a { count = 0; stopped = false };
  Engine.on_event engine (Ping { cid = cid_a });
  Engine.on_event engine (Ping { cid = cid_a });
  match Engine.get engine ~correlation_id:cid_a with
  | Some { count = 2; stopped = false } ->
      Alcotest.(check int) "two pongs dispatched" 2 (List.length (snapshot ()))
  | _ -> Alcotest.fail "expected state count=2"

let test_unknown_cid_silently_dropped () =
  let dispatch, snapshot = collect_dispatch () in
  let engine = make_engine ~dispatch in
  Engine.on_event engine (Ping { cid = "ghost" });
  Alcotest.(check int) "no commands" 0 (List.length (snapshot ()));
  Alcotest.(check int) "no instances" 0 (Engine.active_count engine)

let test_terminal_state_evicts_instance () =
  let dispatch, _ = collect_dispatch () in
  let engine = make_engine ~dispatch in
  Engine.start engine ~correlation_id:cid_a { count = 0; stopped = false };
  Alcotest.(check int) "active before stop" 1 (Engine.active_count engine);
  Engine.on_event engine (Stop { cid = cid_a });
  Alcotest.(check int) "active after stop" 0 (Engine.active_count engine);
  match Engine.get engine ~correlation_id:cid_a with
  | None -> ()
  | Some _ -> Alcotest.fail "terminal instance should be evicted"

let test_concurrent_instances_are_isolated () =
  let dispatch, _ = collect_dispatch () in
  let engine = make_engine ~dispatch in
  Engine.start engine ~correlation_id:cid_a { count = 0; stopped = false };
  Engine.start engine ~correlation_id:cid_b { count = 0; stopped = false };
  Engine.on_event engine (Ping { cid = cid_a });
  Engine.on_event engine (Ping { cid = cid_a });
  Engine.on_event engine (Ping { cid = cid_b });
  let a_count =
    match Engine.get engine ~correlation_id:cid_a with
    | Some s -> s.count
    | None -> -1
  in
  let b_count =
    match Engine.get engine ~correlation_id:cid_b with
    | Some s -> s.count
    | None -> -1
  in
  Alcotest.(check int) "instance A count" 2 a_count;
  Alcotest.(check int) "instance B count" 1 b_count

let test_duplicate_start_raises () =
  let dispatch, _ = collect_dispatch () in
  let engine = make_engine ~dispatch in
  Engine.start engine ~correlation_id:cid_a { count = 0; stopped = false };
  Alcotest.check_raises "duplicate start"
    (Invalid_argument "Workflow_engine[sample].start: saga-A already active") (fun () ->
      Engine.start engine ~correlation_id:cid_a { count = 0; stopped = false })

let test_state_committed_before_dispatch () =
  (* Re-entry from the dispatch callback must see the committed
     state from the just-completed transition, not the pre-image.
     This pins down the lock-then-dispatch ordering documented
     in the .mli. *)
  let engine_ref : Engine.t option ref = ref None in
  let observed = ref (-1) in
  let dispatch (Sample.Pong { cid; n = _ }) =
    match !engine_ref with
    | Some e -> (
        match Engine.get e ~correlation_id:cid with
        | Some s -> observed := s.count
        | None -> observed := -2)
    | None -> ()
  in
  let engine = make_engine ~dispatch in
  engine_ref := Some engine;
  Engine.start engine ~correlation_id:cid_a { count = 0; stopped = false };
  Engine.on_event engine (Ping { cid = cid_a });
  Alcotest.(check int) "dispatch sees committed state" 1 !observed

let tests =
  [
    ("start then event", `Quick, test_start_then_event_transitions_state);
    ("unknown cid dropped", `Quick, test_unknown_cid_silently_dropped);
    ("terminal evicts instance", `Quick, test_terminal_state_evicts_instance);
    ("instances isolated", `Quick, test_concurrent_instances_are_isolated);
    ("duplicate start raises", `Quick, test_duplicate_start_raises);
    ("state committed before dispatch", `Quick, test_state_committed_before_dispatch);
  ]
