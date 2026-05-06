open Core
module Pmr = Portfolio_management.Pair_mean_reversion
module Pm_common = Portfolio_management.Common
module Pair_mr_state = Pmr.Values.Pair_mr_state
module Set_target = Portfolio_management_commands.Set_target_command

type t = { mutable states : Pmr.state ref list }

let make () = { states = [] }
let register t state = t.states <- state :: t.states

let instrument_of_view (vm : Portfolio_management_inbound_queries.Instrument_view_model.t)
    : Instrument.t =
  let qualified =
    match vm.board with
    | Some b -> Printf.sprintf "%s@%s/%s" vm.ticker vm.venue b
    | None -> Printf.sprintf "%s@%s" vm.ticker vm.venue
  in
  Instrument.of_qualified qualified

let candle_of_view (vm : Portfolio_management_inbound_queries.Candle_view_model.t) :
    Candle.t =
  Candle.make ~ts:vm.ts ~open_:(Decimal.of_string vm.open_)
    ~high:(Decimal.of_string vm.high) ~low:(Decimal.of_string vm.low)
    ~close:(Decimal.of_string vm.close) ~volume:(Decimal.of_string vm.volume)

let proposal_to_command (prop : Pm_common.Target_proposal.t) : Set_target.t =
  let positions =
    List.map
      (fun (tp : Pm_common.Target_position.t) : Set_target.position ->
        {
          instrument = Instrument.to_qualified tp.instrument;
          target_qty = Decimal.to_string tp.target_qty;
        })
      prop.positions
  in
  {
    book_id = Pm_common.Book_id.to_string prop.book_id;
    source = prop.source;
    proposed_at = Datetime.Iso8601.format prop.proposed_at;
    positions;
  }

let handle
    (t : t)
    ~(dispatch_set_target : Set_target.t -> unit)
    (ev : Bar_updated_integration_event.t) : unit =
  let instrument = instrument_of_view ev.instrument in
  let candle = candle_of_view ev.bar in
  List.iter
    (fun state_ref ->
      let cfg = Pair_mr_state.config !state_ref in
      if Pm_common.Pair.contains cfg.pair instrument then begin
        let state', proposal_opt = Pmr.on_bar !state_ref ~instrument ~candle in
        state_ref := state';
        match proposal_opt with
        | Some prop -> dispatch_set_target (proposal_to_command prop)
        | None -> ()
      end)
    t.states
