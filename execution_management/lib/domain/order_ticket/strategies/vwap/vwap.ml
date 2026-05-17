(* VWAP state: per-slice quantities precomputed from the
   normalised volume profile. The last slice absorbs residue so
   Σ = total exactly even when weights are float-precision. *)

type state = {
  slice_schedule : Decimal.t array;
      (** [|n_slices|] entries; [.(i)] is the quantity for slice i. *)
  emitted_count : int;
  next_due_at : int64;
  interval_seconds : int64;
  failed : bool;
}

(** Precompute slice quantities: first n-1 from weights, last
    absorbs the residue. *)
let build_schedule ~(total : Decimal.t) ~(profile : float list) : Decimal.t array =
  let weights = Array.of_list profile in
  let n = Array.length weights in
  let total_f = Decimal.to_float total in
  let schedule = Array.make n Decimal.zero in
  let acc_first_n_minus_1 = ref Decimal.zero in
  for i = 0 to n - 2 do
    let q = Decimal.of_float (total_f *. weights.(i)) in
    schedule.(i) <- q;
    acc_first_n_minus_1 := Decimal.add !acc_first_n_minus_1 q
  done;
  schedule.(n - 1) <- Decimal.sub total !acc_first_n_minus_1;
  schedule

let init ~(intent : Values.Trade_intent.t) ~(params : Values.Vwap_params.t)
    ~now:_ =
  let schedule =
    build_schedule ~total:intent.total_quantity
      ~profile:params.volume_profile
  in
  let interval = Int64.of_int (params.window_seconds / params.n_slices) in
  let interval_seconds = if Int64.compare interval 0L = 0 then 1L else interval in
  let state =
    {
      slice_schedule = schedule;
      emitted_count = 0;
      next_due_at = params.start_at;
      interval_seconds;
      failed = false;
    }
  in
  (state, Decision.empty)

let market_submit qty : Decision.submit_request =
  { quantity = qty; kind = Placement.Values.Order_kind.Market; tif = Placement.Values.Tif.Day }

let on_event (state : state) (input : Input.t) ~now:_ : state * Decision.t =
  if state.failed then (state, Decision.empty)
  else
    let n = Array.length state.slice_schedule in
    match input with
    | Input.Tick { now } ->
        if state.emitted_count >= n then (state, Decision.empty)
        else if Int64.compare now state.next_due_at < 0 then
          (state, Decision.empty)
        else
          let qty = state.slice_schedule.(state.emitted_count) in
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
  let n = Array.length state.slice_schedule in
  (not state.failed) && state.emitted_count >= n
