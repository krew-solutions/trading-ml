open Core

module Values = Values
module Events = Events
module Config = Values.Kalman_dlm_config
module State = Values.Kalman_dlm_state
module Direction = Common.Pair_direction

type config = Config.t
type state = State.t

let name = "pair_kalman_mean_reversion"
let init = State.init

let log_close (c : Candle.t) = log (Decimal.to_float c.close)

(* Direction transition under hysteresis. Identical logic to the
   static policy; thresholds operate on the innovation z-score
   (already an empirical-floor standardised residual) rather than
   the rolling-spread z-score. The hysteresis predicate is the
   same: enter on |z| ≥ z_entry, exit on |z| ≤ z_exit. *)
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
              let beta = (State.posterior state').mean_beta in
              let intent =
                Common.Pair_intent_builder.build ~pair:cfg.pair ~book_id:cfg.book_id
                  ~direction:new_dir ~beta
                  ~source:(Common.Source.Pair_kalman_mean_reversion cfg.pair)
                  ~observed_at:candle.ts ~coupling_source:name
              in
              (state'', Some intent)))
