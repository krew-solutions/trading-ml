module Values = Values
module Events = Events

type t = {
  book_id : Common.Book_id.t;
  cash : Decimal.t;
  positions : Values.Position_snapshot.t list;
}

let empty book_id = { book_id; cash = Decimal.zero; positions = [] }

let book_id t = t.book_id
let cash t = t.cash

let position t instrument =
  match
    List.find_opt
      (fun (p : Values.Position_snapshot.t) ->
        Core.Instrument.equal (Values.Position_snapshot.instrument p) instrument)
      t.positions
  with
  | Some p -> Values.Position_snapshot.quantity p
  | None -> Decimal.zero

let positions t =
  List.sort
    (fun (a : Values.Position_snapshot.t) (b : Values.Position_snapshot.t) ->
      Core.Instrument.compare
        (Values.Position_snapshot.instrument a)
        (Values.Position_snapshot.instrument b))
    t.positions

let apply_position_change t ~instrument ~delta_qty ~new_qty ~avg_price ~occurred_at =
  let others =
    List.filter
      (fun (p : Values.Position_snapshot.t) ->
        not (Core.Instrument.equal (Values.Position_snapshot.instrument p) instrument))
      t.positions
  in
  let positions =
    if Decimal.is_zero new_qty then others
    else Values.Position_snapshot.make ~instrument ~quantity:new_qty ~avg_price :: others
  in
  let event =
    Events.Position_recorded.make ~book_id:t.book_id ~instrument ~delta_qty ~new_qty
      ~occurred_at
  in
  ({ t with positions }, event)

let apply_cash_change t ~delta ~new_balance ~occurred_at =
  let event =
    Events.Cash_recorded.make ~book_id:t.book_id ~delta ~new_balance ~occurred_at
  in
  ({ t with cash = new_balance }, event)
