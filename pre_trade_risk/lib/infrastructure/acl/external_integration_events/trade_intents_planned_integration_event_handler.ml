module Trade_intents_planned = Trade_intents_planned_integration_event
module Trade_intent_vm = Pre_trade_risk_external_view_models.Trade_intent_view_model
module Instrument_vm = Pre_trade_risk_external_view_models.Instrument_view_model
module Inbound_directive_vm =
  Pre_trade_risk_external_view_models.Execution_directive_view_model
module Internal_directive_vm = Pre_trade_risk_view_models.Execution_directive_view_model

(** ACL: PM's [Execution_directive_view_model] wire shape is
    regenerated independently in PTR's external_view_models lib
    (against PM's .atd) and in PTR's own view_models lib (against
    PTR's mirror .atd). Both records carry identical fields. The
    translator below is a one-line structural copy that keeps the
    two type universes from leaking across the ACL boundary. *)
let directive_of_inbound (d : Inbound_directive_vm.t) : Internal_directive_vm.t =
  { kind = d.kind; params = d.params }

let qualify (i : Instrument_vm.t) : string =
  let base = Printf.sprintf "%s@%s" i.ticker i.venue in
  match i.board with
  | Some b -> base ^ "/" ^ b
  | None -> base

let avg_price_or_zero
    ~(risk_view_for :
       Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t option)
    (book_id : Pre_trade_risk.Common.Book_id.t)
    (instrument : Core.Instrument.t) : Decimal.t =
  match risk_view_for book_id with
  | None -> Decimal.zero
  | Some view -> (
      match
        List.find_opt
          (fun p ->
            Core.Instrument.equal
              (Pre_trade_risk.Risk_view.Values.Position_snapshot.instrument p)
              instrument)
          (Pre_trade_risk.Risk_view.positions view)
      with
      | None -> Decimal.zero
      | Some p -> Pre_trade_risk.Risk_view.Values.Position_snapshot.avg_price p)

let handle
    ~(risk_view_for :
       Pre_trade_risk.Common.Book_id.t -> Pre_trade_risk.Risk_view.t option)
    ~(dispatch_assess : Pre_trade_risk_commands.Assess_trade_intent_command.t -> unit)
    (ev : Trade_intents_planned.t) : unit =
  List.iter
    (fun (leg : Trade_intents_planned.leg) ->
      let intent = leg.intent in
      let symbol = qualify intent.instrument in
      let book_id =
        try Some (Pre_trade_risk.Common.Book_id.of_string intent.book_id)
        with Invalid_argument _ -> None
      in
      let instrument =
        try Some (Core.Instrument.of_qualified symbol) with Invalid_argument _ -> None
      in
      let price =
        match (book_id, instrument) with
        | Some bid, Some inst ->
            Decimal.to_string (avg_price_or_zero ~risk_view_for bid inst)
        | _ -> Decimal.to_string Decimal.zero
      in
      let execution_directive =
        Option.map directive_of_inbound intent.execution_directive
      in
      let cmd : Pre_trade_risk_commands.Assess_trade_intent_command.t =
        {
          correlation_id = leg.correlation_id;
          book_id = intent.book_id;
          symbol;
          side = intent.side;
          quantity = intent.quantity;
          price;
          execution_directive;
        }
      in
      dispatch_assess cmd)
    ev.trades
