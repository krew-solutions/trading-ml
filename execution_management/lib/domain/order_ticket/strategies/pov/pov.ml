(* POV state: tracks cumulative observed volume and cumulative
   emitted quantity; on each Volume_bar, computes the next
   emission to keep emitted_so_far ≤ rate × observed.

   Note: POV does not consult Tick events. The strategy is purely
   volume-driven; with the Disabled volume_feed adapter, no
   slices are emitted (observable blocking, not silent passivity). *)

type state = {
  total_quantity : Decimal.t;
  participation_rate : float;
  observed_volume : Decimal.t;
  emitted_so_far : Decimal.t;
  failed : bool;
}

let init ~(intent : Values.Trade_intent.t) ~(params : Values.Pov_params.t) ~now:_ =
  let state =
    {
      total_quantity = intent.total_quantity;
      participation_rate = params.participation_rate;
      observed_volume = Decimal.zero;
      emitted_so_far = Decimal.zero;
      failed = false;
    }
  in
  (state, Decision.empty)

let market_submit qty : Decision.submit_request =
  {
    quantity = qty;
    kind = Placement.Values.Order_kind.Market;
    tif = Placement.Values.Tif.Day;
  }

let remaining state = Decimal.sub state.total_quantity state.emitted_so_far

let on_event (state : state) (input : Input.t) ~now:_ : state * Decision.t =
  if state.failed then (state, Decision.empty)
  else
    match input with
    | Input.Volume_bar { bar } ->
        let observed' = Decimal.add state.observed_volume bar.volume in
        let target =
          Decimal.of_float (Decimal.to_float observed' *. state.participation_rate)
        in
        let delta = Decimal.sub target state.emitted_so_far in
        let rem = remaining state in
        let zero_or_pos = if Decimal.is_positive delta then delta else Decimal.zero in
        let emit_qty = Decimal.min rem zero_or_pos in
        if Decimal.is_positive emit_qty then
          let state' =
            {
              state with
              observed_volume = observed';
              emitted_so_far = Decimal.add state.emitted_so_far emit_qty;
            }
          in
          (state', { Decision.empty with submit = [ market_submit emit_qty ] })
        else ({ state with observed_volume = observed' }, Decision.empty)
    | Input.Placement_rejected { reason; _ } ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed ("rejected: " ^ reason) } )
    | Input.Placement_unreachable _ ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed "unreachable" } )
    | Input.Placement_cancelled _ ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed "cancelled" } )
    | Input.Tick _
    | Input.Price_quote _
    | Input.Placement_acknowledged _
    | Input.Placement_filled _ -> (state, Decision.empty)

let is_complete state =
  (not state.failed) && Decimal.compare (remaining state) Decimal.zero <= 0
