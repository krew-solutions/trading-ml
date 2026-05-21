(* Iceberg state: tracks cumulative fill against the current
   outstanding chunk. Strict-serial — only one chunk in flight at
   a time, next chunk emitted only after the current is fully
   filled. *)

type state = {
  visible_qty : Decimal.t;
  remaining_total : Decimal.t;
      (** Total intent quantity not yet covered by completed chunks. *)
  current_chunk_target : Decimal.t;
      (** Size of the outstanding chunk; min(visible_qty, remaining_total). *)
  current_chunk_filled : Decimal.t;
      (** Cumulative fill quantity against the current outstanding chunk. *)
  failed : bool;
}

let chunk_size ~visible_qty ~remaining =
  if Decimal.compare remaining visible_qty <= 0 then remaining else visible_qty

let market_submit qty : Decision.submit_request =
  {
    quantity = qty;
    kind = Placement.Values.Order_kind.Market;
    tif = Placement.Values.Tif.Day;
  }

let init ~(intent : Values.Trade_intent.t) ~(params : Values.Iceberg_params.t) ~now:_ =
  let total = intent.total_quantity in
  let first_chunk = chunk_size ~visible_qty:params.visible_qty ~remaining:total in
  let state =
    {
      visible_qty = params.visible_qty;
      remaining_total = total;
      current_chunk_target = first_chunk;
      current_chunk_filled = Decimal.zero;
      failed = false;
    }
  in
  (state, { Decision.empty with submit = [ market_submit first_chunk ] })

let on_event (state : state) (input : Input.t) ~now:_ : state * Decision.t =
  if state.failed then (state, Decision.empty)
  else
    match input with
    | Input.Placement_filled { fill; _ } ->
        let new_chunk_filled = Decimal.add state.current_chunk_filled fill.quantity in
        if Decimal.compare new_chunk_filled state.current_chunk_target < 0 then
          (* Partial fill within current chunk — no new submit. *)
          ({ state with current_chunk_filled = new_chunk_filled }, Decision.empty)
        else
          (* Current chunk complete — advance. *)
          let new_remaining =
            Decimal.sub state.remaining_total state.current_chunk_target
          in
          if Decimal.compare new_remaining Decimal.zero <= 0 then
            (* Whole intent done. *)
            let state' =
              {
                state with
                remaining_total = Decimal.zero;
                current_chunk_filled = new_chunk_filled;
              }
            in
            (state', { Decision.empty with terminal = Decision.Completed })
          else
            let next_chunk =
              chunk_size ~visible_qty:state.visible_qty ~remaining:new_remaining
            in
            let state' =
              {
                state with
                remaining_total = new_remaining;
                current_chunk_target = next_chunk;
                current_chunk_filled = Decimal.zero;
              }
            in
            (state', { Decision.empty with submit = [ market_submit next_chunk ] })
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
    | Input.Volume_bar _
    | Input.Price_quote _
    | Input.Placement_acknowledged _ -> (state, Decision.empty)

let is_complete state =
  (not state.failed) && Decimal.compare state.remaining_total Decimal.zero <= 0
