open Core

module Events = Events

let intent_for ~book_id ~instrument ~target_qty ~actual_qty : Common.Trade_intent.t option
    =
  let delta = Decimal.sub target_qty actual_qty in
  if Decimal.is_zero delta then None
  else
    let side = if Decimal.is_positive delta then Side.Buy else Side.Sell in
    let quantity = Decimal.abs delta in
    Some ({ book_id; instrument; side; quantity } : Common.Trade_intent.t)

(* Build the union of instruments across [target] and [actual]. We
   walk both lists (each sorted by [Instrument.compare]) in parallel
   to produce a sorted, deduplicated key list. *)
let union_instruments target_positions actual_positions =
  let rec go acc t a =
    match (t, a) with
    | [], [] -> List.rev acc
    | (tp : Common.Target_position.t) :: ts, [] -> go (tp.instrument :: acc) ts []
    | [], (ap : Actual_portfolio.Values.Actual_position.t) :: as_ ->
        go (ap.instrument :: acc) [] as_
    | ( (tp : Common.Target_position.t) :: ts,
        (ap : Actual_portfolio.Values.Actual_position.t) :: as_ ) ->
        let c = Instrument.compare tp.instrument ap.instrument in
        if c = 0 then go (tp.instrument :: acc) ts as_
        else if c < 0 then go (tp.instrument :: acc) ts (ap :: as_)
        else go (ap.instrument :: acc) (tp :: ts) as_
  in
  go [] target_positions actual_positions

let diff ~(target : Target_portfolio.t) ~(actual : Actual_portfolio.t) :
    Common.Trade_intent.t list =
  let book_id = Target_portfolio.book_id target in
  let instruments =
    union_instruments
      (Target_portfolio.positions target)
      (Actual_portfolio.positions actual)
  in
  List.filter_map
    (fun instrument ->
      let target_qty = Target_portfolio.target_for target instrument in
      let actual_qty = Actual_portfolio.position actual instrument in
      intent_for ~book_id ~instrument ~target_qty ~actual_qty)
    instruments

let diff_with_event ~target ~actual ~computed_at :
    Common.Trade_intent.t list * Events.Trades_planned.t =
  let trades = diff ~target ~actual in
  let event : Events.Trades_planned.t =
    { book_id = Target_portfolio.book_id target; trades; computed_at }
  in
  (trades, event)
