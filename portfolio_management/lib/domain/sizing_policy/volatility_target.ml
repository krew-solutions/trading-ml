open Core

type config = { target_annual_vol : Decimal.t }

let name = "volatility_target"

(* Per-leg qty for the vol-target formula. Returns Decimal.zero
   on any of the refusal cases (stale mark, zero equity, vol
   unavailable, zero vol) so the policy degrades to "do nothing
   on this leg" rather than blow up — and a leg with qty=0 is
   pruned by Target_portfolio downstream. *)
let qty_of
    ~(target_annual_vol : Decimal.t)
    ~(book_equity : Decimal.t)
    ~(mark_price : Decimal.t)
    ~(weight : Decimal.t)
    ~(instrument_vol : Decimal.t option) : Decimal.t =
  if not (Decimal.is_positive mark_price) then Decimal.zero
  else
    match instrument_vol with
    | None -> Decimal.zero
    | Some sigma when not (Decimal.is_positive sigma) -> Decimal.zero
    | Some sigma ->
        let vol_scale = Decimal.div target_annual_vol sigma in
        let dim = Decimal.mul weight vol_scale in
        let notional = Decimal.mul book_equity dim in
        if Decimal.is_zero notional then Decimal.zero
        else Decimal.div notional mark_price

let scalar_weight ~(direction : Common.Direction.t)
    ~(strength : Common.Strength.t) : Decimal.t =
  let s = Common.Strength.to_decimal strength in
  match direction with
  | Common.Direction.Up -> s
  | Common.Direction.Down -> Decimal.neg s
  | Common.Direction.Flat -> Decimal.zero

let size_scalar (cfg : config) ~book_equity ~mark ~volatility
    ~(book_id : Common.Book_id.t) ~(instrument : Instrument.t)
    ~direction ~strength ~source ~observed_at :
    Common.Target_proposal.t =
  let weight = scalar_weight ~direction ~strength in
  let target_qty =
    qty_of ~target_annual_vol:cfg.target_annual_vol ~book_equity
      ~mark_price:(mark instrument) ~weight
      ~instrument_vol:(volatility instrument)
  in
  let position : Common.Target_position.t =
    { book_id; instrument; target_qty; coupling = None }
  in
  {
    book_id;
    positions = [ position ];
    source = Common.Source.to_string source;
    proposed_at = observed_at;
  }

let size_coupled (cfg : config) ~book_equity ~mark ~volatility
    ~(book_id : Common.Book_id.t)
    ~(legs : Common.Construction_intent.leg list)
    ~(coupling : Common.Coupling.t) ~source ~observed_at :
    Common.Target_proposal.t =
  let positions =
    List.map
      (fun (leg : Common.Construction_intent.leg) ->
        let target_qty =
          qty_of ~target_annual_vol:cfg.target_annual_vol ~book_equity
            ~mark_price:(mark leg.instrument) ~weight:leg.weight
            ~instrument_vol:(volatility leg.instrument)
        in
        ({
           book_id;
           instrument = leg.instrument;
           target_qty;
           coupling = Some coupling;
         }
          : Common.Target_position.t))
      legs
  in
  {
    book_id;
    positions;
    source = Common.Source.to_string source;
    proposed_at = observed_at;
  }

let size (cfg : config) ~book_equity ~mark ~volatility
    (intent : Common.Construction_intent.t) : Common.Target_proposal.t =
  match intent with
  | Common.Construction_intent.Scalar s ->
      size_scalar cfg ~book_equity ~mark ~volatility ~book_id:s.book_id
        ~instrument:s.instrument ~direction:s.direction
        ~strength:s.strength ~source:s.source ~observed_at:s.observed_at
  | Common.Construction_intent.Coupled c ->
      size_coupled cfg ~book_equity ~mark ~volatility ~book_id:c.book_id
        ~legs:c.legs ~coupling:c.coupling ~source:c.source
        ~observed_at:c.observed_at
