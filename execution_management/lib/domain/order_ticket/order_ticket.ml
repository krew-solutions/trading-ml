module Values = Values
module Placement = Placement
module Events = Events
module Strategies = Strategies

type lifecycle =
  | Working of Strategies.Strategy.t
  | Cancelling of {
      strategy : Strategies.Strategy.t;
      reason : Values.Cancel_reason.t;
    }
  | Filled
  | Cancelled of Values.Cancel_reason.t
  | Failed of string

type t = {
  ticket_id : Values.Ticket_id.t;
  intent : Values.Trade_intent.t;
  directive : Values.Execution_directive.t;
  lifecycle : lifecycle;
  next_placement_seq : int;
  placements : Placement.t list;
      (** Reverse-chronological order (most recent first). Lookup
          by id walks the list; the count of in-flight placements
          is small (≤ n_slices) so linear scan is fine. *)
  progress : Values.Progress.t;
}

type event =
  | Ev_ticket_opened of Events.Ticket_opened.t
  | Ev_placement_dispatched of Events.Placement_dispatched.t
  | Ev_placement_acknowledged of Events.Placement_acknowledged.t
  | Ev_placement_filled of Events.Placement_filled.t
  | Ev_placement_rejected of Events.Placement_rejected.t
  | Ev_placement_unreachable of Events.Placement_unreachable.t
  | Ev_placement_cancelled of Events.Placement_cancelled.t
  | Ev_ticket_cancelling_started of Events.Ticket_cancelling_started.t
  | Ev_ticket_completed of Events.Ticket_completed.t
  | Ev_ticket_cancelled of Events.Ticket_cancelled.t
  | Ev_ticket_failed of Events.Ticket_failed.t

(* ---------- Inspection ---------- *)

let ticket_id t = t.ticket_id
let intent t = t.intent
let directive t = t.directive
let lifecycle t = t.lifecycle
let progress t = t.progress
let placements t = List.rev t.placements

let find_placement t pid =
  List.find_opt
    (fun (p : Placement.t) ->
      Placement.Values.Placement_id.equal p.id pid)
    t.placements

let is_terminal t =
  match t.lifecycle with
  | Filled | Cancelled _ | Failed _ -> true
  | Working _ | Cancelling _ -> false

(* ---------- Internal helpers ---------- *)

let mint_placement_id t =
  let next = t.next_placement_seq in
  let pid = Placement.Values.Placement_id.of_int next in
  let t' = { t with next_placement_seq = next + 1 } in
  (t', pid)

let materialise_submit t (req : Strategies.Decision.submit_request) ~now =
  let t', pid = mint_placement_id t in
  let placement =
    Placement.pending ~id:pid ~requested_quantity:req.quantity ~kind:req.kind
      ~tif:req.tif
  in
  let event =
    Events.Placement_dispatched.make ~ticket_id:t.ticket_id ~placement_id:pid
      ~quantity:req.quantity ~kind:req.kind ~tif:req.tif ~occurred_at:now
  in
  let t'' = { t' with placements = placement :: t'.placements } in
  (t'', Ev_placement_dispatched event)

let materialise_submits t (submits : Strategies.Decision.submit_request list)
    ~now =
  let final_state, rev_events =
    List.fold_left
      (fun (acc_t, acc_evs) req ->
        let t', ev = materialise_submit acc_t req ~now in
        (t', ev :: acc_evs))
      (t, []) submits
  in
  (final_state, List.rev rev_events)

let update_placement t pid f =
  let placements =
    List.map
      (fun (p : Placement.t) ->
        if Placement.Values.Placement_id.equal p.id pid then f p else p)
      t.placements
  in
  { t with placements }

let outstanding_placements t =
  List.filter
    (fun (p : Placement.t) -> not (Placement.is_terminal p))
    t.placements

let outstanding_placement_ids t =
  List.map (fun (p : Placement.t) -> p.id) (outstanding_placements t)

let all_placements_terminal t =
  List.for_all Placement.is_terminal t.placements

let apply_strategy_terminal t (terminal : Strategies.Decision.terminal) ~now =
  match terminal with
  | Strategies.Decision.Continue | Strategies.Decision.Completed ->
      (t.lifecycle, None)
  | Strategies.Decision.Failed reason ->
      let ev =
        Events.Ticket_failed.make ~ticket_id:t.ticket_id ~reason
          ~progress:t.progress ~occurred_at:now
      in
      (Failed reason, Some (Ev_ticket_failed ev))

let check_full_fill t ~now =
  if Values.Progress.is_fully_filled t.progress && not (is_terminal t) then
    let ev =
      Events.Ticket_completed.make ~ticket_id:t.ticket_id ~progress:t.progress
        ~occurred_at:now
    in
    let t' = { t with lifecycle = Filled } in
    (t', Some (Ev_ticket_completed ev))
  else (t, None)

let check_cancellation_settled t ~now =
  match t.lifecycle with
  | Cancelling { reason; _ } when all_placements_terminal t ->
      if Values.Progress.is_fully_filled t.progress then
        let ev =
          Events.Ticket_completed.make ~ticket_id:t.ticket_id
            ~progress:t.progress ~occurred_at:now
        in
        ({ t with lifecycle = Filled }, Some (Ev_ticket_completed ev))
      else
        let ev =
          Events.Ticket_cancelled.make ~ticket_id:t.ticket_id ~reason
            ~progress:t.progress ~occurred_at:now
        in
        ({ t with lifecycle = Cancelled reason }, Some (Ev_ticket_cancelled ev))
  | _ -> (t, None)

(* ---------- open_ticket ---------- *)

let open_ticket ~ticket_id ~intent ~directive ~now =
  let strategy, decision =
    Strategies.Strategy.init ~intent ~directive ~now
  in
  let progress = Values.Progress.empty ~total_quantity:intent.total_quantity in
  let initial =
    {
      ticket_id;
      intent;
      directive;
      lifecycle = Working strategy;
      next_placement_seq = 1;
      placements = [];
      progress;
    }
  in
  let t_after_submits, placement_events =
    materialise_submits initial decision.submit ~now
  in
  let opened =
    Events.Ticket_opened.make ~ticket_id ~intent ~directive ~occurred_at:now
  in
  let events = Ev_ticket_opened opened :: placement_events in
  let lifecycle', terminal_event =
    apply_strategy_terminal t_after_submits decision.terminal ~now
  in
  let t' = { t_after_submits with lifecycle = lifecycle' } in
  match terminal_event with
  | None -> (t', events)
  | Some ev -> (t', events @ [ ev ])

(* ---------- Strategy dispatch helper ---------- *)

let dispatch_strategy_input t (input : Strategies.Input.t) ~now =
  match t.lifecycle with
  | Filled | Cancelled _ | Failed _ -> (t, [])
  | Working strategy ->
      let strategy', decision =
        Strategies.Strategy.on_event strategy input ~now
      in
      let t_with_strategy = { t with lifecycle = Working strategy' } in
      let t_after_submits, dispatched_events =
        materialise_submits t_with_strategy decision.submit ~now
      in
      let lifecycle', terminal_event =
        apply_strategy_terminal t_after_submits decision.terminal ~now
      in
      let t' = { t_after_submits with lifecycle = lifecycle' } in
      let evs =
        match terminal_event with
        | Some ev -> dispatched_events @ [ ev ]
        | None -> dispatched_events
      in
      (t', evs)
  | Cancelling { strategy; reason } ->
      let strategy', _decision =
        Strategies.Strategy.on_event strategy input ~now
      in
      let t' =
        {
          t with
          lifecycle = Cancelling { strategy = strategy'; reason };
        }
      in
      (t', [])

(* ---------- Placement-event operations ---------- *)

let on_placement_acknowledged t ~placement_id ~now =
  if is_terminal t then (t, [])
  else
    match find_placement t placement_id with
    | None -> (t, [])
    | Some p when Placement.is_terminal p -> (t, [])
    | Some _ ->
        let t1 = update_placement t placement_id Placement.acknowledge in
        let ev =
          Events.Placement_acknowledged.make ~ticket_id:t.ticket_id
            ~placement_id ~occurred_at:now
        in
        let t2, strategy_evs =
          dispatch_strategy_input t1
            (Strategies.Input.Placement_acknowledged { placement_id })
            ~now
        in
        (t2, Ev_placement_acknowledged ev :: strategy_evs)

let on_placement_fill t ~placement_id ~fill ~now =
  if is_terminal t then (t, [])
  else
    match find_placement t placement_id with
    | None -> (t, [])
    | Some p when Placement.is_terminal p -> (t, [])
    | Some _ ->
        let t1 =
          update_placement t placement_id (fun p ->
              Placement.apply_fill p ~fill)
        in
        let progress' = Values.Progress.apply_fill t.progress ~fill in
        let t2 = { t1 with progress = progress' } in
        let filled_ev =
          Events.Placement_filled.make ~ticket_id:t.ticket_id ~placement_id
            ~fill ~occurred_at:now
        in
        let t3, strategy_evs =
          dispatch_strategy_input t2
            (Strategies.Input.Placement_filled { placement_id; fill })
            ~now
        in
        let t4, completed_ev = check_full_fill t3 ~now in
        let t5, cancelled_or_completed_ev =
          check_cancellation_settled t4 ~now
        in
        let trailing =
          List.filter_map Fun.id [ completed_ev; cancelled_or_completed_ev ]
        in
        (t5, (Ev_placement_filled filled_ev :: strategy_evs) @ trailing)

let on_placement_rejection t ~placement_id ~reason ~now =
  if is_terminal t then (t, [])
  else
    match find_placement t placement_id with
    | None -> (t, [])
    | Some p when Placement.is_terminal p -> (t, [])
    | Some _ ->
        let t1 = update_placement t placement_id Placement.reject in
        let rej_ev =
          Events.Placement_rejected.make ~ticket_id:t.ticket_id ~placement_id
            ~reason ~occurred_at:now
        in
        let t2, strategy_evs =
          dispatch_strategy_input t1
            (Strategies.Input.Placement_rejected { placement_id; reason })
            ~now
        in
        let t3, settled_ev = check_cancellation_settled t2 ~now in
        let trailing = match settled_ev with Some e -> [ e ] | None -> [] in
        (t3, (Ev_placement_rejected rej_ev :: strategy_evs) @ trailing)

let on_placement_unreachable t ~placement_id ~now =
  if is_terminal t then (t, [])
  else
    match find_placement t placement_id with
    | None -> (t, [])
    | Some p when Placement.is_terminal p -> (t, [])
    | Some _ ->
        let t1 = update_placement t placement_id Placement.unreachable in
        let unr_ev =
          Events.Placement_unreachable.make ~ticket_id:t.ticket_id
            ~placement_id ~occurred_at:now
        in
        let t2, strategy_evs =
          dispatch_strategy_input t1
            (Strategies.Input.Placement_unreachable { placement_id })
            ~now
        in
        let t3, settled_ev = check_cancellation_settled t2 ~now in
        let trailing = match settled_ev with Some e -> [ e ] | None -> [] in
        (t3, (Ev_placement_unreachable unr_ev :: strategy_evs) @ trailing)

let on_placement_cancelled t ~placement_id ~now =
  if is_terminal t then (t, [])
  else
    match find_placement t placement_id with
    | None -> (t, [])
    | Some p when Placement.is_terminal p -> (t, [])
    | Some _ ->
        let t1 = update_placement t placement_id Placement.cancel in
        let canc_ev =
          Events.Placement_cancelled.make ~ticket_id:t.ticket_id ~placement_id
            ~occurred_at:now
        in
        let t2, strategy_evs =
          dispatch_strategy_input t1
            (Strategies.Input.Placement_cancelled { placement_id })
            ~now
        in
        let t3, settled_ev = check_cancellation_settled t2 ~now in
        let trailing = match settled_ev with Some e -> [ e ] | None -> [] in
        (t3, (Ev_placement_cancelled canc_ev :: strategy_evs) @ trailing)

(* ---------- Clock / market-data inputs ---------- *)

let on_clock_tick t ~now =
  dispatch_strategy_input t (Strategies.Input.Tick { now }) ~now

let on_volume_bar t ~bar ~now =
  dispatch_strategy_input t (Strategies.Input.Volume_bar { bar }) ~now

(* ---------- Operator cancel ---------- *)

let cancel t ~reason ~now =
  match t.lifecycle with
  | Filled | Cancelled _ | Failed _ | Cancelling _ -> (t, [])
  | Working strategy ->
      let outstanding = outstanding_placement_ids t in
      let ev =
        Events.Ticket_cancelling_started.make ~ticket_id:t.ticket_id ~reason
          ~outstanding_placements:outstanding ~occurred_at:now
      in
      let t1 = { t with lifecycle = Cancelling { strategy; reason } } in
      let t2, settled_ev = check_cancellation_settled t1 ~now in
      let trailing = match settled_ev with Some e -> [ e ] | None -> [] in
      (t2, Ev_ticket_cancelling_started ev :: trailing)
