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

(* Build the proposal that realises [direction] at the supplied close
   prices. Sizing: [notional / close_a] units of A,
   [β · notional / close_b] units of B; signs per direction. *)
let proposal_for_direction
    ~(config : Config.t)
    ~(direction : Direction.t)
    ~(close_a : Decimal.t)
    ~(close_b : Decimal.t)
    ~(proposed_at : int64) : Common.Target_proposal.t =
  let beta = Common.Hedge_ratio.to_decimal config.hedge_ratio in
  let qty_a =
    if Decimal.is_zero close_a then Decimal.zero else Decimal.div config.notional close_a
  in
  let qty_b =
    if Decimal.is_zero close_b then Decimal.zero
    else Decimal.div (Decimal.mul beta config.notional) close_b
  in
  let signed_a, signed_b =
    match direction with
    | Direction.Flat -> (Decimal.zero, Decimal.zero)
    | Direction.Long_spread -> (qty_a, Decimal.neg qty_b)
    | Direction.Short_spread -> (Decimal.neg qty_a, qty_b)
  in
  let a = Common.Pair.a config.pair in
  let b = Common.Pair.b config.pair in
  let positions : Common.Target_position.t list =
    [
      { book_id = config.book_id; instrument = a; target_qty = signed_a };
      { book_id = config.book_id; instrument = b; target_qty = signed_b };
    ]
  in
  { book_id = config.book_id; positions; source = name; proposed_at }

let on_bar (state : State.t) ~instrument ~candle :
    State.t * Common.Target_proposal.t option =
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
              let recover_close = function
                | Some lx -> Decimal.of_float (Float.exp lx)
                | None -> Decimal.zero
              in
              let close_a =
                match which with
                | `A -> candle.close
                | `B -> recover_close (State.last_log_close state' ~leg:`A)
              in
              let close_b =
                match which with
                | `B -> candle.close
                | `A -> recover_close (State.last_log_close state' ~leg:`B)
              in
              let state'' = State.with_direction state' new_dir in
              let proposal =
                proposal_for_direction ~config:cfg ~direction:new_dir ~close_a ~close_b
                  ~proposed_at:candle.ts
              in
              (state'', Some proposal)))
