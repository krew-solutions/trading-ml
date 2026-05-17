(* TWAP state: per-slice quantities are precomputed (equal share
   for slices 0..n-2, residue carried by slice n-1 so Σ = total
   exactly). The next_due timestamp advances by [interval_seconds]
   per emission.

   The strategy tracks [failed] explicitly so terminal absorbtion
   is local to the strategy. *)

type state = {
  per_slice_quantity : Decimal.t;
  last_slice_quantity : Decimal.t;  (** total − (n−1) × per_slice — exact residue *)
  n_slices : int;
  emitted_count : int;
  next_due_at : int64;
  interval_seconds : int64;
  failed : bool;
}

let init ~(intent : Values.Trade_intent.t) ~(params : Values.Twap_params.t)
    ~now:_ =
  let total = intent.total_quantity in
  let n = params.n_slices in
  let per_slice = Decimal.div total (Decimal.of_int n) in
  let last_slice =
    Decimal.sub total (Decimal.mul per_slice (Decimal.of_int (n - 1)))
  in
  let interval = Int64.of_int (params.window_seconds / n) in
  let interval_seconds = if Int64.compare interval 0L = 0 then 1L else interval in
  let state =
    {
      per_slice_quantity = per_slice;
      last_slice_quantity = last_slice;
      n_slices = n;
      emitted_count = 0;
      next_due_at = params.start_at;
      interval_seconds;
      failed = false;
    }
  in
  (state, Decision.empty)

let next_slice_quantity state =
  if state.emitted_count = state.n_slices - 1 then state.last_slice_quantity
  else state.per_slice_quantity

let market_submit qty : Decision.submit_request =
  { quantity = qty; kind = Placement.Values.Order_kind.Market; tif = Placement.Values.Tif.Day }

let on_event (state : state) (input : Input.t) ~now:_ : state * Decision.t =
  if state.failed then (state, Decision.empty)
  else
    match input with
    | Input.Tick { now } ->
        if state.emitted_count >= state.n_slices then (state, Decision.empty)
        else if Int64.compare now state.next_due_at < 0 then
          (state, Decision.empty)
        else
          let qty = next_slice_quantity state in
          let state' =
            {
              state with
              emitted_count = state.emitted_count + 1;
              next_due_at = Int64.add state.next_due_at state.interval_seconds;
            }
          in
          ( state',
            { Decision.empty with submit = [ market_submit qty ] } )
    | Input.Placement_rejected { reason; _ } ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed ("rejected: " ^ reason) }
        )
    | Input.Placement_unreachable _ ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed "unreachable" } )
    | Input.Placement_cancelled _ ->
        ( { state with failed = true },
          { Decision.empty with terminal = Decision.Failed "cancelled" } )
    | Input.Placement_acknowledged _ | Input.Placement_filled _
    | Input.Volume_bar _ | Input.Price_quote _ ->
        (state, Decision.empty)

let is_complete state =
  (not state.failed) && state.emitted_count >= state.n_slices
