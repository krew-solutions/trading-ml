open Core

(* Re-exports define the aggregate's public surface. *)
module Values = Values
module Events = Events

(* Local shortcuts. *)
module Actual_position = Values.Actual_position
module Actual_fill_committed = Events.Actual_fill_committed

type t = {
  book_id : Common.Book_id.t;
  cash : Decimal.t;
  positions : Actual_position.t list;
      (* invariants:
         - sorted by Instrument.compare on [instrument];
         - no duplicate [instrument] entries;
         - no entry with [quantity = 0] (zeros are pruned). *)
}

let empty book_id = { book_id; cash = Decimal.zero; positions = [] }

let book_id p = p.book_id

let cash p = p.cash

let position p instrument =
  match
    List.find_opt
      (fun (pos : Actual_position.t) -> Instrument.equal pos.instrument instrument)
      p.positions
  with
  | Some pos -> pos.quantity
  | None -> Decimal.zero

let positions p = p.positions

(* Insert / overwrite [pos] into [positions] keeping sort order and
   the no-zero-quantity invariant. *)
let upsert positions (pos : Actual_position.t) =
  let zero_qty = Decimal.is_zero pos.quantity in
  let rec go acc = function
    | [] -> if zero_qty then List.rev acc else List.rev_append acc [ pos ]
    | (cur : Actual_position.t) :: rest ->
        let c = Instrument.compare cur.instrument pos.instrument in
        if c = 0 then
          if zero_qty then List.rev_append acc rest else List.rev_append acc (pos :: rest)
        else if c > 0 then
          if zero_qty then List.rev_append acc (cur :: rest)
          else List.rev_append acc (pos :: cur :: rest)
        else go (cur :: acc) rest
  in
  go [] positions

let commit_fill
    p
    ~(instrument : Instrument.t)
    ~(new_position_quantity : Decimal.t)
    ~(new_avg_price : Decimal.t)
    ~(new_cash : Decimal.t)
    ~(occurred_at : int64) : t * Actual_fill_committed.t =
  let pos : Actual_position.t =
    { instrument; quantity = new_position_quantity; avg_price = new_avg_price }
  in
  let positions' = upsert p.positions pos in
  let event : Actual_fill_committed.t =
    {
      book_id = p.book_id;
      instrument;
      new_position_quantity;
      new_avg_price;
      new_cash;
      occurred_at;
    }
  in
  ({ p with cash = new_cash; positions = positions' }, event)
