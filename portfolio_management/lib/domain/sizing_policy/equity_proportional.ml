open Core

type config = unit

let name = "equity_proportional"

(* Compute target_qty = book_equity × weight / mark, with the
   stale-mark sentinel (mark ≤ 0 ⇒ qty = 0). *)
let qty_of ~book_equity ~mark_price ~weight =
  if not (Decimal.is_positive mark_price) then Decimal.zero
  else
    let notional = Decimal.mul book_equity weight in
    if Decimal.is_zero notional then Decimal.zero else Decimal.div notional mark_price

(* Weight for a scalar intent: direction-sign × strength.
   Returns Decimal in [-1, 1]. *)
let scalar_weight ~(direction : Common.Direction.t) ~(strength : Common.Strength.t) :
    Decimal.t =
  let s = Common.Strength.to_decimal strength in
  match direction with
  | Common.Direction.Up -> s
  | Common.Direction.Down -> Decimal.neg s
  | Common.Direction.Flat -> Decimal.zero

let size_scalar
    ~book_equity
    ~mark
    ~(book_id : Common.Book_id.t)
    ~(instrument : Instrument.t)
    ~direction
    ~strength
    ~source
    ~observed_at : Common.Target_proposal.t =
  let weight = scalar_weight ~direction ~strength in
  let target_qty = qty_of ~book_equity ~mark_price:(mark instrument) ~weight in
  let position : Common.Target_position.t =
    { book_id; instrument; target_qty; coupling = None }
  in
  {
    book_id;
    positions = [ position ];
    source = Common.Source.to_string source;
    proposed_at = observed_at;
  }

let size_coupled
    ~book_equity
    ~mark
    ~(book_id : Common.Book_id.t)
    ~(legs : Common.Construction_intent.leg list)
    ~(coupling : Common.Coupling.t)
    ~source
    ~observed_at : Common.Target_proposal.t =
  let positions =
    List.map
      (fun (leg : Common.Construction_intent.leg) ->
        let target_qty =
          qty_of ~book_equity ~mark_price:(mark leg.instrument) ~weight:leg.weight
        in
        ({ book_id; instrument = leg.instrument; target_qty; coupling = Some coupling }
          : Common.Target_position.t))
      legs
  in
  {
    book_id;
    positions;
    source = Common.Source.to_string source;
    proposed_at = observed_at;
  }

let size () ~book_equity ~mark ~volatility:_ (intent : Common.Construction_intent.t) :
    Common.Target_proposal.t =
  match intent with
  | Common.Construction_intent.Scalar s ->
      size_scalar ~book_equity ~mark ~book_id:s.book_id ~instrument:s.instrument
        ~direction:s.direction ~strength:s.strength ~source:s.source
        ~observed_at:s.observed_at
  | Common.Construction_intent.Coupled c ->
      size_coupled ~book_equity ~mark ~book_id:c.book_id ~legs:c.legs ~coupling:c.coupling
        ~source:c.source ~observed_at:c.observed_at
