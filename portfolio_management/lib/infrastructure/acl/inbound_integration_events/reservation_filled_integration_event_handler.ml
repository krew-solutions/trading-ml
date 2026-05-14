module Reservation_filled = Reservation_filled_integration_event

(* PR-1 sentinel: Account is single-book today and its outbound IE
   carries no [book_id]. Tracked as a follow-up; see the .mli. *)
let sentinel_book_id = "alpha"

let to_command ~(now : unit -> int64) (ev : Reservation_filled.t) :
    Portfolio_management_commands.Commit_actual_fill_command.t =
  let instrument =
    let i = ev.instrument in
    match i.board with
    | Some b -> Printf.sprintf "%s@%s/%s" i.ticker i.venue b
    | None -> Printf.sprintf "%s@%s" i.ticker i.venue
  in
  (* IE carries no occurred_at; read ambient time from the injected
     clock. Live deployments wire wall-clock; backtest deployments
     wire a virtual clock advanced from the bar stream. *)
  let occurred_at = Datetime.Iso8601.format (now ()) in
  {
    book_id = sentinel_book_id;
    instrument;
    new_position_quantity = ev.new_position_quantity;
    new_avg_price = ev.new_avg_price;
    new_cash = ev.new_cash;
    occurred_at;
  }

let handle
    ~(now : unit -> int64)
    ~(dispatch_commit_actual_fill :
       Portfolio_management_commands.Commit_actual_fill_command.t -> unit)
    (ev : Reservation_filled.t) : unit =
  dispatch_commit_actual_fill (to_command ~now ev)
