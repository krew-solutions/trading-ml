(** In-process test harness for the Pre_trade_risk BC.

    Drives the application-layer workflows
    ({!Assess_trade_intent_command_workflow},
    {!Record_fill_command_workflow}) — not the handlers — so the
    component boundary covered by these tests includes outbound
    integration-event publication.

    Per-book {!Risk_view.t} state lives in a {!Hashtbl} keyed by
    {!Common.Book_id}; outbound integration events are appended to
    in-memory recorders (one per topic) that the Then-steps
    inspect. *)

module Assess_wf = Pre_trade_risk_commands.Assess_trade_intent_command_workflow
module Assess_h = Pre_trade_risk_commands.Assess_trade_intent_command_handler
module Record_fill_wf = Pre_trade_risk_commands.Record_fill_command_workflow
module Record_fill_h = Pre_trade_risk_commands.Record_fill_command_handler

module Trade_intent_approved_ie =
  Pre_trade_risk_integration_events.Trade_intent_approved_integration_event

module Trade_intent_rejected_ie =
  Pre_trade_risk_integration_events.Trade_intent_rejected_integration_event

type ctx = {
  views : (string, Pre_trade_risk.Risk_view.t ref) Hashtbl.t;
      (** Per-book Risk_view, keyed by [Book_id.to_string]. Tests start
          with no books seeded; the [seed_book] helper provisions one
          on demand. *)
  limits : Pre_trade_risk.Risk_limits.t;
  mark : Core.Instrument.t -> Decimal.t option;
  approved_pub : Trade_intent_approved_ie.t list ref;
  rejected_pub : Trade_intent_rejected_ie.t list ref;
  last_assess_result : (unit, Assess_h.handle_error) Rop.t option;
  last_record_fill_result : (unit, Record_fill_h.handle_error) Rop.t option;
}

let default_limits =
  Pre_trade_risk.Risk_limits.make ~min_cash_buffer:Decimal.zero
    ~max_gross_exposure:(Decimal.of_int 1_000_000) ~max_leverage:5.0

let default_mark : Core.Instrument.t -> Decimal.t option = fun _ -> None

let fresh_ctx () =
  {
    views = Hashtbl.create 4;
    limits = default_limits;
    mark = default_mark;
    approved_pub = ref [];
    rejected_pub = ref [];
    last_assess_result = None;
    last_record_fill_result = None;
  }

let with_limits ctx ~limits = { ctx with limits }
let with_mark ctx ~mark = { ctx with mark }

(** Provision a fresh, empty Risk_view for the given book id. *)
let seed_book ctx ~book_id =
  let bid = Pre_trade_risk.Common.Book_id.of_string book_id in
  Hashtbl.replace ctx.views book_id (ref (Pre_trade_risk.Risk_view.empty bid));
  ctx

let ensure_view ctx ~book_id =
  match Hashtbl.find_opt ctx.views book_id with
  | Some r -> r
  | None ->
      let bid = Pre_trade_risk.Common.Book_id.of_string book_id in
      let r = ref (Pre_trade_risk.Risk_view.empty bid) in
      Hashtbl.add ctx.views book_id r;
      r

(** Direct-seed the cash side of a book's Risk_view, bypassing the
    application pipeline. Used by Given-steps to set up preconditions
    without forcing each scenario to publish a Reservation_filled. *)
let with_cash ctx ~book_id ~cash =
  let r = ensure_view ctx ~book_id in
  let cash_d = Decimal.of_string cash in
  (* Commit-fill at quantity 0 keeps positions untouched (the entry
     for the sentinel instrument never existed; the [is_zero] branch
     prevents insertion) while replacing [cash]. *)
  let sentinel = Core.Instrument.of_qualified "SBER@MISX" in
  let v, _ =
    Pre_trade_risk.Risk_view.commit_fill !r ~instrument:sentinel
      ~new_position_quantity:Decimal.zero ~new_avg_price:Decimal.zero ~new_cash:cash_d
      ~occurred_at:0L
  in
  r := v;
  ctx

(** Direct-seed a position. To preserve the existing [cash] value
    in the underlying view, we read it back and pass it through. *)
let with_position ctx ~book_id ~symbol ~qty ~avg_price =
  let r = ensure_view ctx ~book_id in
  let qty_d = Decimal.of_string qty in
  let avg_d = Decimal.of_string avg_price in
  let instrument = Core.Instrument.of_qualified symbol in
  let current_cash = Pre_trade_risk.Risk_view.cash !r in
  let v, _ =
    Pre_trade_risk.Risk_view.commit_fill !r ~instrument ~new_position_quantity:qty_d
      ~new_avg_price:avg_d ~new_cash:current_cash ~occurred_at:0L
  in
  r := v;
  ctx

let risk_view_for ctx (book_id : Pre_trade_risk.Common.Book_id.t) =
  match Hashtbl.find_opt ctx.views (Pre_trade_risk.Common.Book_id.to_string book_id) with
  | Some r -> Some !r
  | None -> None

let risk_view_ref_for ctx (book_id : Pre_trade_risk.Common.Book_id.t) =
  let key = Pre_trade_risk.Common.Book_id.to_string book_id in
  match Hashtbl.find_opt ctx.views key with
  | Some r -> r
  | None ->
      let r = ref (Pre_trade_risk.Risk_view.empty book_id) in
      Hashtbl.add ctx.views key r;
      r

let assess ctx ~book_id ~side ~symbol ~quantity ~price =
  let cmd : Pre_trade_risk_commands.Assess_trade_intent_command.t =
    {
      correlation_id = Correlation_id.to_string (Correlation_id.generate ());
      book_id;
      symbol;
      side;
      quantity;
      price;
    }
  in
  let publish_approved e = ctx.approved_pub := e :: !(ctx.approved_pub) in
  let publish_rejected e = ctx.rejected_pub := e :: !(ctx.rejected_pub) in
  let result =
    Assess_wf.execute ~risk_view_for:(risk_view_for ctx) ~limits:ctx.limits ~mark:ctx.mark
      ~publish_approved ~publish_rejected cmd
  in
  { ctx with last_assess_result = Some result }

let record_fill ctx ~book_id ~symbol ~new_position_quantity ~new_avg_price ~new_cash =
  let cmd : Pre_trade_risk_commands.Record_fill_command.t =
    {
      book_id;
      symbol;
      new_position_quantity;
      new_avg_price;
      new_cash;
      occurred_at = "2024-01-01T00:00:00Z";
    }
  in
  let result = Record_fill_wf.execute ~risk_view_ref_for:(risk_view_ref_for ctx) cmd in
  { ctx with last_record_fill_result = Some result }
