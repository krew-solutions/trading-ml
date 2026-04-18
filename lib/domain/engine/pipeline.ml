open Core

type event = {
  bar : Candle.t;
  state : Step.state;
  settled : (Signal.t * Step.settled) option;
}

let run (cfg : Step.config) (state0 : Step.state)
  : Candle.t Stream.t -> event Stream.t =
  Stream.scan_filter_map state0 (fun (state : Step.state) (c : Candle.t) ->
    if Int64.compare c.ts state.last_bar_ts <= 0 then
      (* Stale or duplicate bar — pipeline skips, state untouched. *)
      state, None
    else
      let state1, fill_opt = Step.execute_pending cfg state c in
      let state2 = Step.advance_strategy cfg state1 c in
      state2, Some { bar = c; state = state2; settled = fill_opt })

let equity_at_close (e : event) : Decimal.t =
  let mark _ = Some e.bar.Candle.close in
  Portfolio.equity e.state.portfolio mark
