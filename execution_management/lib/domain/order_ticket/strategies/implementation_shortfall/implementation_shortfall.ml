(* Implementation Shortfall: precompute the Almgren-Chriss
   trajectory at init, then emit slices in order on subsequent
   ticks. The trajectory's slice quantities use float arithmetic
   for sinh(); the final slice absorbs the residue so
   Σ slice_qty = total_quantity exactly even when float ops lose
   the last ULP. *)

type slice = { due_at : int64; quantity : Decimal.t }

type state = { trajectory : slice array; emitted_count : int; failed : bool }

(** Build the schedule. Slice i (1-indexed in the math, 0-indexed
    in the array) covers the interval [t_{i-1}, t_i]; its
    quantity is x(t_{i-1}) - x(t_i). For numerical robustness
    against extreme κT, we evaluate sinh in float; the residue
    trick on the last slice covers any rounding. *)
let build_trajectory
    ~(total : Decimal.t)
    ~(params : Values.Implementation_shortfall_params.t) : slice array =
  let n = params.n_slices in
  let window = float_of_int params.window_seconds in
  let total_f = Decimal.to_float total in
  let kappa =
    sqrt (params.risk_aversion *. (params.volatility ** 2.0) /. params.temp_impact_eta)
  in
  let denom = sinh (kappa *. window) in
  (* x(t) as a fraction of total; degenerate kappa*T ≈ 0 falls
     back to linear schedule (TWAP equivalent). *)
  let remaining_fraction t =
    if denom = 0.0 || not (Float.is_finite denom) then 1.0 -. (t /. window)
    else sinh (kappa *. (window -. t)) /. denom
  in
  let trajectory = Array.make n { due_at = 0L; quantity = Decimal.zero } in
  let acc_first_n_minus_1 = ref Decimal.zero in
  for i = 0 to n - 2 do
    let t_prev = float_of_int i *. window /. float_of_int n in
    let t_next = float_of_int (i + 1) *. window /. float_of_int n in
    let slice_q =
      Decimal.of_float
        (total_f *. (remaining_fraction t_prev -. remaining_fraction t_next))
    in
    let due_at = Int64.add params.start_at (Int64.of_int (int_of_float t_next)) in
    trajectory.(i) <- { due_at; quantity = slice_q };
    acc_first_n_minus_1 := Decimal.add !acc_first_n_minus_1 slice_q
  done;
  let last_due_at = Int64.add params.start_at (Int64.of_int params.window_seconds) in
  trajectory.(n - 1) <-
    { due_at = last_due_at; quantity = Decimal.sub total !acc_first_n_minus_1 };
  trajectory

let init
    ~(intent : Values.Trade_intent.t)
    ~(params : Values.Implementation_shortfall_params.t)
    ~now:_ =
  let trajectory = build_trajectory ~total:intent.total_quantity ~params in
  let state = { trajectory; emitted_count = 0; failed = false } in
  (state, Decision.empty)

let market_submit qty : Decision.submit_request =
  {
    quantity = qty;
    kind = Placement.Values.Order_kind.Market;
    tif = Placement.Values.Tif.Day;
  }

let on_event (state : state) (input : Input.t) ~now:_ : state * Decision.t =
  if state.failed then (state, Decision.empty)
  else
    let n = Array.length state.trajectory in
    match input with
    | Input.Tick { now } ->
        if state.emitted_count >= n then (state, Decision.empty)
        else
          let next = state.trajectory.(state.emitted_count) in
          if Int64.compare now next.due_at < 0 then (state, Decision.empty)
          else
            let state' = { state with emitted_count = state.emitted_count + 1 } in
            (state', { Decision.empty with submit = [ market_submit next.quantity ] })
    | Input.Placement_rejected { reason; _ } ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed ("rejected: " ^ reason) } )
    | Input.Placement_unreachable _ ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed "unreachable" } )
    | Input.Placement_cancelled _ ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed "cancelled" } )
    | Input.Volume_bar _
    | Input.Price_quote _
    | Input.Placement_acknowledged _
    | Input.Placement_filled _ -> (state, Decision.empty)

let is_complete state =
  let n = Array.length state.trajectory in
  (not state.failed) && state.emitted_count >= n
