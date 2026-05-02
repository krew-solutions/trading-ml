(** In-process test harness for the Account BC.

    Drives the application-layer workflows ({!Reserve_command_workflow}
    / {!Release_command_workflow}) — not the handlers — so the
    component boundary covered by these tests includes the outbound
    integration-event projection. The Hexagonal outbound ports
    [publish_*] are substituted with in-memory recorders: each
    publication is appended to a per-scenario [ref] list that the
    Then-steps inspect. *)

module Reserve_wf = Account_commands.Reserve_command_workflow
module Release_wf = Account_commands.Release_command_workflow

module Reserve_h = Account_commands.Reserve_command_handler
(** Re-exposed only for the [handle_error] variants — the test
    pattern-matches them on the [Rop.t] tail of the workflow result
    when the [Validation] track fires. *)

module Release_h = Account_commands.Release_command_handler

module Amount_reserved_ie = Account_integration_events.Amount_reserved_integration_event

module Reservation_rejected_ie =
  Account_integration_events.Reservation_rejected_integration_event

module Reservation_released_ie =
  Account_integration_events.Reservation_released_integration_event

type ctx = {
  portfolio : Account.Portfolio.t ref;
  next_reservation_id : unit -> int;
  slippage_buffer : Decimal.t;
  fee_rate : Decimal.t;
  amount_reserved_pub : Amount_reserved_ie.t list ref;
  reservation_rejected_pub : Reservation_rejected_ie.t list ref;
  reservation_released_pub : Reservation_released_ie.t list ref;
  last_reserve_result : (unit, Reserve_h.handle_error) Rop.t option;
  last_release_result : (unit, Release_h.handle_error) Rop.t option;
}

let make_id_counter () =
  let r = ref 0 in
  fun () ->
    incr r;
    !r

let fresh_ctx () =
  {
    portfolio = ref (Account.Portfolio.empty ~cash:(Decimal.of_int 10_000));
    next_reservation_id = make_id_counter ();
    slippage_buffer = Decimal.of_string "0.01";
    fee_rate = Decimal.of_string "0.001";
    amount_reserved_pub = ref [];
    reservation_rejected_pub = ref [];
    reservation_released_pub = ref [];
    last_reserve_result = None;
    last_release_result = None;
  }

let with_cash ctx ~cash =
  ctx.portfolio := Account.Portfolio.empty ~cash:(Decimal.of_string cash);
  ctx

let with_slippage ctx ~buffer = { ctx with slippage_buffer = Decimal.of_string buffer }

let with_fee_rate ctx ~rate = { ctx with fee_rate = Decimal.of_string rate }

let reserve ctx ~side ~symbol ~quantity ~price =
  let cmd : Account_commands.Reserve_command.t = { side; symbol; quantity; price } in
  let publish_amount_reserved e =
    ctx.amount_reserved_pub := e :: !(ctx.amount_reserved_pub)
  in
  let publish_reservation_rejected e =
    ctx.reservation_rejected_pub := e :: !(ctx.reservation_rejected_pub)
  in
  let result =
    Reserve_wf.execute ~portfolio:ctx.portfolio
      ~next_reservation_id:ctx.next_reservation_id ~slippage_buffer:ctx.slippage_buffer
      ~fee_rate:ctx.fee_rate ~publish_amount_reserved ~publish_reservation_rejected cmd
  in
  { ctx with last_reserve_result = Some result }

let release ctx ~reservation_id =
  let cmd : Account_commands.Release_command.t = { reservation_id } in
  let publish_reservation_released e =
    ctx.reservation_released_pub := e :: !(ctx.reservation_released_pub)
  in
  let result =
    Release_wf.execute ~portfolio:ctx.portfolio ~publish_reservation_released cmd
  in
  { ctx with last_release_result = Some result }
