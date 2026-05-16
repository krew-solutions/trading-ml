(* Immediate's job is small: emit one submit at init, then watch
   the placement's terminal verdict. State tracks lifecycle stage. *)

type lifecycle =
  | Pending  (** Submitted; awaiting broker terminal verdict. *)
  | Completed  (** Filled (quantity = total). *)
  | Failed of string  (** Rejected / unreachable / cancelled. *)

type state = {
  total_quantity : Decimal.t;
  lifecycle : lifecycle;
}

let init ~(intent : Values.Trade_intent.t) ~now:_ =
  let state = { total_quantity = intent.total_quantity; lifecycle = Pending } in
  let submit : Decision.submit_request =
    { quantity = intent.total_quantity; kind = Values.Order_kind.Market; tif = Values.Tif.Day }
  in
  let decision : Decision.t =
    { submit = [ submit ]; cancel = []; terminal = Decision.Continue }
  in
  (state, decision)

let fail_state state reason = { state with lifecycle = Failed reason }

let on_event state (input : Input.t) ~now:_ : state * Decision.t =
  match state.lifecycle with
  | Completed | Failed _ ->
      (* Terminal: late events are absorbed; the aggregate enforces
         idempotency at its boundary too. *)
      (state, Decision.empty)
  | Pending -> (
      match input with
      | Input.Placement_acknowledged _ ->
          (* Acknowledgement is informational for Immediate — no
             new submits, no terminal yet. *)
          (state, Decision.empty)
      | Input.Placement_filled { fill; _ } ->
          let new_state =
            if Decimal.compare fill.quantity state.total_quantity >= 0 then
              { state with lifecycle = Completed }
            else
              (* Partial fill — Immediate stays pending; the
                 aggregate's cumulative progress decides the
                 ticket's terminal state when [Σ filled = total]. *)
              state
          in
          let terminal =
            match new_state.lifecycle with
            | Completed -> Decision.Completed
            | _ -> Decision.Continue
          in
          (new_state, { Decision.empty with terminal })
      | Input.Placement_rejected { reason; _ } ->
          let new_state = fail_state state reason in
          ( new_state,
            { Decision.empty with terminal = Decision.Failed ("rejected: " ^ reason) } )
      | Input.Placement_unreachable _ ->
          let new_state = fail_state state "unreachable" in
          ( new_state,
            { Decision.empty with terminal = Decision.Failed "unreachable" } )
      | Input.Placement_cancelled _ ->
          let new_state = fail_state state "cancelled" in
          ( new_state,
            { Decision.empty with terminal = Decision.Failed "cancelled" } )
      | Input.Tick _ ->
          (* Immediate is event-driven only; ticks are irrelevant. *)
          (state, Decision.empty))

let is_complete state =
  match state.lifecycle with Completed -> true | Pending | Failed _ -> false
