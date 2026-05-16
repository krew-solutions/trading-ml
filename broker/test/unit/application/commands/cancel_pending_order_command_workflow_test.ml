(** Sociable tests for {!Broker_commands.Cancel_pending_order_command_workflow}.

    The Submit/Cancel handshake is exercised against an
    in-process fake of the {!Broker.S} port. The fake mimics an
    ACL adapter — it owns an internal {[placement_id ↦ string]}
    map and returns the canned view-model status the test
    instructs it to. *)

open Core
module Order_view_model = Broker_view_models.Order_view_model
module Execution_view_model = Broker_view_models.Execution_view_model
module Submit = Broker_commands.Submit_order_command
module Submit_wf = Broker_commands.Submit_order_command_workflow
module Cancel = Broker_commands.Cancel_pending_order_command
module Cancel_wf = Broker_commands.Cancel_pending_order_command_workflow
module Cancel_handler = Broker_commands.Cancel_pending_order_command_handler
module Order_cancelled = Broker_integration_events.Order_cancelled_integration_event

module Fake_broker = struct
  type t = {
    mutable next_cancel_status : string;
    mutable cancel_calls : int list;
    placements : (int, string) Hashtbl.t;
  }

  let create ?(next_cancel_status = "CANCELLED") () =
    { next_cancel_status; cancel_calls = []; placements = Hashtbl.create 8 }

  let name = "fake"
  let venues _ = []
  let bars _ ~n:_ ~instrument:_ ~timeframe:_ = []

  let view_model ~placement_id ~status : Order_view_model.t =
    {
      placement_id;
      instrument = { ticker = "SBER"; venue = "MISX"; isin = None; board = None };
      side = "BUY";
      quantity = "10";
      filled = "0";
      remaining = "10";
      kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
      tif = "GTC";
      status;
      created_ts = 0L;
    }

  let next_cid = ref 0
  let reset_id_seq () = next_cid := 0

  let place_order_by_placement_id
      t
      ~placement_id
      ~instrument:_
      ~side:_
      ~quantity:_
      ~kind:_
      ~tif:_ =
    incr next_cid;
    Hashtbl.replace t.placements placement_id (Printf.sprintf "cid-%d" !next_cid);
    view_model ~placement_id ~status:"NEW"

  let cancel_order_by_placement_id t ~placement_id =
    t.cancel_calls <- placement_id :: t.cancel_calls;
    match Hashtbl.find_opt t.placements placement_id with
    | None -> None
    | Some _ -> Some (view_model ~placement_id ~status:t.next_cancel_status)

  let get_order_by_placement_id t ~placement_id =
    match Hashtbl.find_opt t.placements placement_id with
    | None -> None
    | Some _ -> Some (view_model ~placement_id ~status:"NEW")

  let get_executions_by_placement_id _ ~placement_id:_ = []
end

let fake_client (fb : Fake_broker.t) : Broker.client = Broker.make (module Fake_broker) fb

let command_log_module =
  (module Broker_persistence.In_memory_order_command_log
  : Broker_store.Order_command_log.S
    with type t = Broker_persistence.In_memory_order_command_log.t)

let sample_submit_command ~placement_id ~correlation_id : Submit.t =
  {
    correlation_id;
    placement_id;
    symbol = "SBER@MISX";
    side = "BUY";
    quantity = "10";
    kind = { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
    tif = "GTC";
  }

let submit_one ~fb ~log ~placement_id ~correlation_id =
  let _ : (unit, _) Rop.t =
    Submit_wf.execute ~broker:(fake_client fb) ~command_log:command_log_module
      ~command_log_handle:log
      ~publish_accepted:(fun _ -> ())
      ~publish_rejected:(fun _ -> ())
      ~publish_unreachable:(fun _ -> ())
      (sample_submit_command ~placement_id ~correlation_id)
  in
  ()

let test_cancel_confirmed_publishes_ie () =
  Fake_broker.reset_id_seq ();
  let fb = Fake_broker.create ~next_cancel_status:"CANCELLED" () in
  let log = Broker_persistence.In_memory_order_command_log.create () in
  submit_one ~fb ~log ~placement_id:42 ~correlation_id:"saga-A";
  let cancelled = ref [] in
  let result =
    Cancel_wf.execute ~broker:(fake_client fb) ~command_log:command_log_module
      ~command_log_handle:log
      ~now_ts:(fun () -> 1_700_000_100L)
      ~publish_order_cancelled:(fun ie -> cancelled := ie :: !cancelled)
      { correlation_id = "cancel-A"; placement_id = 42 }
  in
  Alcotest.(check bool) "workflow Ok" true (Result.is_ok result);
  Alcotest.(check (list int)) "cancel called with pid 42" [ 42 ] fb.cancel_calls;
  Alcotest.(check (option string))
    "submit correlation preserved in log" (Some "saga-A")
    (Broker_persistence.In_memory_order_command_log.origin_correlation_id log
       ~placement_id:42);
  Alcotest.(check (option string))
    "cancel correlation recorded" (Some "cancel-A")
    (Broker_persistence.In_memory_order_command_log.cancel_correlation_id log
       ~placement_id:42);
  match !cancelled with
  | [ ie ] ->
      Alcotest.(check string)
        "correlation_id from cancel cmd" "cancel-A" ie.correlation_id;
      Alcotest.(check int) "placement_id" 42 ie.placement_id;
      Alcotest.(check string)
        "cancelled_ts iso8601" "2023-11-14T22:15:00Z" ie.cancelled_ts
  | _ -> Alcotest.fail "expected exactly one Order_cancelled IE"

let test_cancel_pending_publishes_ie () =
  Fake_broker.reset_id_seq ();
  let fb = Fake_broker.create ~next_cancel_status:"PENDING_CANCEL" () in
  let log = Broker_persistence.In_memory_order_command_log.create () in
  submit_one ~fb ~log ~placement_id:7 ~correlation_id:"saga-P";
  let cancelled = ref [] in
  let _ =
    Cancel_wf.execute ~broker:(fake_client fb) ~command_log:command_log_module
      ~command_log_handle:log
      ~now_ts:(fun () -> 1_700_000_200L)
      ~publish_order_cancelled:(fun ie -> cancelled := ie :: !cancelled)
      { correlation_id = "cancel-P"; placement_id = 7 }
  in
  Alcotest.(check int)
    "exactly one IE emitted on PENDING_CANCEL" 1 (List.length !cancelled)

let test_cancel_refused_no_ie () =
  Fake_broker.reset_id_seq ();
  let fb = Fake_broker.create ~next_cancel_status:"FILLED" () in
  let log = Broker_persistence.In_memory_order_command_log.create () in
  submit_one ~fb ~log ~placement_id:9 ~correlation_id:"saga-F";
  let cancelled = ref [] in
  let result =
    Cancel_wf.execute ~broker:(fake_client fb) ~command_log:command_log_module
      ~command_log_handle:log
      ~now_ts:(fun () -> 1_700_000_300L)
      ~publish_order_cancelled:(fun ie -> cancelled := ie :: !cancelled)
      { correlation_id = "cancel-F"; placement_id = 9 }
  in
  Alcotest.(check bool) "workflow still Ok on refused" true (Result.is_ok result);
  Alcotest.(check int) "no IE for already-terminal order" 0 (List.length !cancelled);
  Alcotest.(check (option string))
    "no cancel correlation logged on refused" None
    (Broker_persistence.In_memory_order_command_log.cancel_correlation_id log
       ~placement_id:9)

let test_cancel_unknown_placement_yields_resolution_error () =
  let fb = Fake_broker.create () in
  let log = Broker_persistence.In_memory_order_command_log.create () in
  let cancelled = ref [] in
  let result =
    Cancel_wf.execute ~broker:(fake_client fb) ~command_log:command_log_module
      ~command_log_handle:log
      ~now_ts:(fun () -> 1L)
      ~publish_order_cancelled:(fun ie -> cancelled := ie :: !cancelled)
      { correlation_id = "cancel-X"; placement_id = 999_999 }
  in
  Alcotest.(check int) "no IE emitted" 0 (List.length !cancelled);
  match result with
  | Error [ Cancel_handler.Resolution (Placement_not_found 999_999) ] -> ()
  | _ -> Alcotest.fail "expected Placement_not_found"

let tests =
  [
    ( "cancel on CANCELLED status publishes Order_cancelled IE",
      `Quick,
      test_cancel_confirmed_publishes_ie );
    ( "cancel on PENDING_CANCEL status publishes Order_cancelled IE",
      `Quick,
      test_cancel_pending_publishes_ie );
    ("cancel on already-terminal order emits no IE", `Quick, test_cancel_refused_no_ie);
    ( "cancel for unknown placement_id yields Placement_not_found",
      `Quick,
      test_cancel_unknown_placement_yields_resolution_error );
  ]
