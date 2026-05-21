(** In-process harness for OrderTicket command workflows.

    Mirrors the slice of the factory's wiring that's relevant to
    aggregate-level scenarios: an in-memory ticket_store, a fixed
    clock, and a recording [publish] callback whose contents the
    Then-steps assert on. *)

module Ot = Execution_management.Order_ticket
module Values = Ot.Values
module Store = Execution_management_persistence.In_memory_ticket_store
module Ports = Execution_management_ports
module Cmds = Execution_management_commands

type ctx = { store : Store.t; events : Ot.event list ref; now : unit -> int64 }

let store_module = (module Store : Ports.Ticket_store.S with type t = Store.t)

let fresh_ctx () =
  let now_ref = ref 1_700_000_000L in
  let now () =
    let v = !now_ref in
    now_ref := Int64.add v 1L;
    v
  in
  { store = Store.create (); events = ref []; now }

let publish ctx ev = ctx.events := ev :: !(ctx.events)
let emitted ctx = List.rev !(ctx.events)
let qty s = Decimal.of_string s

let open_immediate_ticket ?directive ctx ~ticket_id ~correlation_id =
  let cmd : Cmds.Open_order_ticket_command.t =
    {
      reservation_id = ticket_id;
      correlation_id;
      book_id = "alpha";
      symbol = "SBER@MISX";
      side = "BUY";
      quantity = "100";
      execution_directive = directive;
    }
  in
  match
    Cmds.Open_order_ticket_command_workflow.execute ~store:store_module
      ~store_handle:ctx.store ~publish:(publish ctx) ~now:ctx.now cmd
  with
  | Ok _ -> ctx
  | Error errs ->
      Alcotest.failf "open_immediate_ticket failed: %s"
        (String.concat "; " (List.map Cmds.Command_error.to_string errs))

let cancel_ticket ctx ~ticket_id ~reason =
  let cmd : Cmds.Cancel_order_ticket_command.t = { ticket_id; reason } in
  match
    Cmds.Cancel_order_ticket_command_workflow.execute ~store:store_module
      ~store_handle:ctx.store ~publish:(publish ctx) ~now:ctx.now cmd
  with
  | Ok () -> ctx
  | Error errs ->
      Alcotest.failf "cancel_ticket failed: %s"
        (String.concat "; " (List.map Cmds.Command_error.to_string errs))

let apply_placement_cancelled ctx ~ticket_id ~placement_id =
  let cmd : Cmds.Apply_placement_cancelled_command.t = { ticket_id; placement_id } in
  match
    Cmds.Apply_placement_cancelled_command_workflow.execute ~store:store_module
      ~store_handle:ctx.store ~publish:(publish ctx) ~now:ctx.now cmd
  with
  | Ok () -> ctx
  | Error errs ->
      Alcotest.failf "apply_placement_cancelled failed: %s"
        (String.concat "; " (List.map Cmds.Command_error.to_string errs))

let apply_placement_fill ctx ~ticket_id ~placement_id ~quantity =
  let cmd : Cmds.Apply_placement_leg_fill_command.t =
    {
      ticket_id;
      placement_id;
      fill_quantity = quantity;
      fill_price = "250";
      fee = "0.5";
      fill_ts = 1_700_000_000L;
    }
  in
  match
    Cmds.Apply_placement_leg_fill_command_workflow.execute ~store:store_module
      ~store_handle:ctx.store ~publish:(publish ctx) ~now:ctx.now cmd
  with
  | Ok () -> ctx
  | Error errs ->
      Alcotest.failf "apply_placement_fill failed: %s"
        (String.concat "; " (List.map Cmds.Command_error.to_string errs))

let ticket ctx ~ticket_id = Store.get ctx.store (Values.Ticket_id.of_int ticket_id)

let lifecycle ctx ~ticket_id =
  match ticket ctx ~ticket_id with
  | Some t -> Ot.lifecycle t
  | None -> Alcotest.failf "ticket %d not in store" ticket_id

let count_kind p events = List.length (List.filter p events)

let is_cancelling_started = function
  | Ot.Ev_ticket_cancelling_started _ -> true
  | _ -> false

let is_ticket_cancelled = function
  | Ot.Ev_ticket_cancelled _ -> true
  | _ -> false

let is_placement_dispatched = function
  | Ot.Ev_placement_dispatched _ -> true
  | _ -> false

let is_ticket_completed = function
  | Ot.Ev_ticket_completed _ -> true
  | _ -> false

let outstanding_after_open ctx ~ticket_id =
  match ticket ctx ~ticket_id with
  | None -> []
  | Some t -> List.map (fun (p : Ot.Placement.t) -> p.id) (Ot.placements t)
