module Reservation_filled = Reservation_filled_integration_event
module Instrument_vm = Pre_trade_risk_inbound_queries.Instrument_view_model

(* PR-1 sentinel: Account is single-book today and its outbound IE
   carries no [book_id]. Tracked as a follow-up; see the .mli. *)
let sentinel_book_id = "alpha"

let qualify (i : Instrument_vm.t) : string =
  let base = Printf.sprintf "%s@%s" i.ticker i.venue in
  match i.board with
  | Some b -> base ^ "/" ^ b
  | None -> base

let handle
    ~(now : unit -> int64)
    ~(dispatch_record_fill : Pre_trade_risk_commands.Record_fill_command.t -> unit)
    (ev : Reservation_filled.t) : unit =
  (* IE carries no occurred_at; read ambient time from the injected
     clock. See ADR 0013. *)
  let occurred_at = Datetime.Iso8601.format (now ()) in
  let cmd : Pre_trade_risk_commands.Record_fill_command.t =
    {
      book_id = sentinel_book_id;
      symbol = qualify ev.instrument;
      new_position_quantity = ev.new_position_quantity;
      new_avg_price = ev.new_avg_price;
      new_cash = ev.new_cash;
      occurred_at;
    }
  in
  dispatch_record_fill cmd
