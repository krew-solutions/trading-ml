let beta_floor = 1e-6

let build
    ~(pair : Pair.t)
    ~(book_id : Book_id.t)
    ~(direction : Pair_direction.t)
    ~(beta : float)
    ~(source : Source.t)
    ~(observed_at : int64)
    ~(coupling_source : string) : Construction_intent.t =
  let beta_clamped = if beta < beta_floor then beta_floor else beta in
  let beta_dec = Decimal.of_float beta_clamped in
  let denom = Decimal.add Decimal.one beta_dec in
  let w_mag_a =
    if Decimal.is_zero denom then Decimal.zero else Decimal.div Decimal.one denom
  in
  let w_mag_b =
    if Decimal.is_zero denom then Decimal.zero else Decimal.div beta_dec denom
  in
  let w_a, w_b =
    match direction with
    | Pair_direction.Flat -> (Decimal.zero, Decimal.zero)
    | Pair_direction.Long_spread -> (w_mag_a, Decimal.neg w_mag_b)
    | Pair_direction.Short_spread -> (Decimal.neg w_mag_a, w_mag_b)
  in
  let a = Pair.a pair in
  let b = Pair.b pair in
  let legs : Construction_intent.leg list =
    [ { instrument = a; weight = w_a }; { instrument = b; weight = w_b } ]
  in
  let coupling = Coupling.make ~source:coupling_source observed_at in
  Construction_intent.coupled ~book_id ~legs ~coupling ~source ~observed_at
