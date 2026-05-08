module Position_changed = Position_changed_integration_event
module Instrument_vm = Pre_trade_risk_inbound_queries.Instrument_view_model

let qualify (i : Instrument_vm.t) : string =
  let base = Printf.sprintf "%s@%s" i.ticker i.venue in
  match i.board with
  | Some b -> base ^ "/" ^ b
  | None -> base

let handle
    ~(dispatch_record_position :
       Pre_trade_risk_commands.Record_position_command.t -> unit)
    (ev : Position_changed.t) : unit =
  let cmd : Pre_trade_risk_commands.Record_position_command.t =
    {
      book_id = ev.book_id;
      symbol = qualify ev.instrument;
      delta_qty = ev.delta_qty;
      new_qty = ev.new_qty;
      avg_price = ev.avg_price;
      occurred_at = ev.occurred_at;
    }
  in
  dispatch_record_position cmd
