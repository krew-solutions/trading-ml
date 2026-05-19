open Core

module Values = Values
module Events = Events
module Config = Values.Pair_mr_config
module State = Values.Pair_mr_state
module Direction = Values.Pair_mr_state.Direction

type config = Config.t
type state = State.t

let name = "pair_mean_reversion"
let init = State.init

let log_close (c : Candle.t) = log (Decimal.to_float c.close)

(* Direction transition under hysteresis. *)
let next_direction ~(config : Config.t) ~(current : Direction.t) ~(z : float) :
    Direction.t option =
  let z_entry = Common.Z_score.to_float config.z_entry in
  let z_exit = Common.Z_score.to_float config.z_exit in
  match current with
  | Direction.Flat ->
      if z >= z_entry then Some Direction.Short_spread
      else if z <= -.z_entry then Some Direction.Long_spread
      else None
  | Direction.Long_spread | Direction.Short_spread ->
      if Float.abs z <= z_exit then Some Direction.Flat else None

(* Build the dimensionless {!Construction_intent.Coupled} that
   realises [direction] for the configured pair under [β].
   Weights:
     - magnitude: A-leg gets [1 / (1 + β)], B-leg gets [β / (1 + β)]
       so that Σ |w| = 1 (full book exposure when not flat);
     - sign: Long_spread = (+A, -B); Short_spread = (-A, +B);
       Flat collapses to zero-weight legs.
   The shared {!Coupling.t} ties both legs together so
   {!Risk_policy.clip}'s per-instrument pass preserves the
   β-ratio under any per-instrument cap. *)
let intent_for_direction
    ~(config : Config.t)
    ~(direction : Direction.t)
    ~(observed_at : int64) : Common.Construction_intent.t =
  let beta = Common.Hedge_ratio.to_decimal config.hedge_ratio in
  let denom = Decimal.add Decimal.one beta in
  let w_mag_a =
    if Decimal.is_zero denom then Decimal.zero
    else Decimal.div Decimal.one denom
  in
  let w_mag_b =
    if Decimal.is_zero denom then Decimal.zero
    else Decimal.div beta denom
  in
  let w_a, w_b =
    match direction with
    | Direction.Flat -> (Decimal.zero, Decimal.zero)
    | Direction.Long_spread -> (w_mag_a, Decimal.neg w_mag_b)
    | Direction.Short_spread -> (Decimal.neg w_mag_a, w_mag_b)
  in
  let a = Common.Pair.a config.pair in
  let b = Common.Pair.b config.pair in
  let legs : Common.Construction_intent.leg list =
    [
      { instrument = a; weight = w_a };
      { instrument = b; weight = w_b };
    ]
  in
  let coupling =
    Common.Coupling.make ~source:name observed_at
  in
  Common.Construction_intent.coupled ~book_id:config.book_id ~legs
    ~coupling
    ~source:(Common.Source.Pair_mean_reversion config.pair)
    ~observed_at

let on_bar (state : State.t) ~instrument ~candle :
    State.t * Common.Construction_intent.t option =
  let cfg = State.config state in
  let pair = cfg.pair in
  let leg =
    if Instrument.equal (Common.Pair.a pair) instrument then Some `A
    else if Instrument.equal (Common.Pair.b pair) instrument then Some `B
    else None
  in
  match leg with
  | None -> (state, None)
  | Some which -> (
      let state' =
        State.record_log_close state ~leg:which ~log_close:(log_close candle)
      in
      match State.current_z state' with
      | None -> (state', None)
      | Some z -> (
          let current = State.direction state' in
          match next_direction ~config:cfg ~current ~z with
          | None -> (state', None)
          | Some new_dir ->
              let state'' = State.with_direction state' new_dir in
              let intent =
                intent_for_direction ~config:cfg ~direction:new_dir
                  ~observed_at:candle.ts
              in
              (state'', Some intent)))
