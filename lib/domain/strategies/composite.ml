(** Composite strategy: combines N child strategies under a voting
    policy. Each child runs independently; their signals are
    aggregated per bar into a single output.

    This module itself implements [Strategy.S], so a composite is
    indistinguishable from a leaf strategy — it can be backtested,
    registered, or nested into another composite. *)

open Core

type policy =
  | Unanimous
  | Majority
  | Any

type params = {
  policy : policy;
  children : Strategy.t list;
}

type state = {
  st_policy : policy;
  st_children : Strategy.t list;
}

let name = "Composite"

let default_params = {
  policy = Majority;
  children = [];
}

let init p = {
  st_policy = p.policy;
  st_children = p.children;
}

(** Per-action vote: count of voters + averaged strength. *)
type vote_entry = {
  action : Signal.action;
  count : int;
  avg_strength : float;
}

let tally (signals : Signal.t list) : vote_entry list =
  let count_for action =
    let voters =
      List.filter (fun (s : Signal.t) -> s.action = action) signals in
    match voters with
    | [] -> None
    | _ ->
      let avg =
        List.fold_left (fun acc (s : Signal.t) -> acc +. s.strength)
          0.0 voters
        /. float_of_int (List.length voters)
      in
      Some { action; count = List.length voters; avg_strength = avg }
  in
  List.filter_map Fun.id [
    count_for Signal.Exit_long;
    count_for Signal.Exit_short;
    count_for Signal.Enter_long;
    count_for Signal.Enter_short;
  ]

let pick_winner ~policy ~total (votes : vote_entry list)
    : (Signal.action * float) option =
  if total = 0 then None
  else
    let is_exit a = a = Signal.Exit_long || a = Signal.Exit_short in
    let exits = List.filter (fun v -> is_exit v.action) votes in
    let candidates = if exits <> [] then exits else votes in
    let best = List.fold_left (fun best v ->
      match best with
      | None -> Some v
      | Some b -> if v.count > b.count then Some v else Some b
    ) None candidates in
    match best with
    | None -> None
    | Some v ->
      let passes = match policy with
        | Unanimous -> v.count = total
        | Majority  -> v.count * 2 > total
        | Any       -> v.count >= 1
      in
      if passes then Some (v.action, v.avg_strength) else None

let on_candle st instrument candle =
  let children', signals =
    List.fold_left (fun (cs, sigs) child ->
      let c', sig_ = Strategy.on_candle child instrument candle in
      c' :: cs, sig_ :: sigs)
      ([], []) st.st_children
  in
  let children' = List.rev children' in
  let signals = List.rev signals in
  let non_hold =
    List.filter (fun (s : Signal.t) -> s.action <> Signal.Hold) signals in
  (* Unanimous/Majority: denominator = all children (Hold = "no").
     Any: denominator = active voters only (Hold = abstain). *)
  let total = match st.st_policy with
    | Unanimous | Majority -> List.length signals
    | Any -> List.length non_hold
  in
  let votes = tally non_hold in
  let action, strength = match pick_winner ~policy:st.st_policy ~total votes with
    | Some (a, s) -> a, s
    | None -> Signal.Hold, 0.0
  in
  let reason =
    if action = Signal.Hold then ""
    else
      let voters =
        List.filter (fun (s : Signal.t) -> s.action = action) non_hold in
      Printf.sprintf "%d/%d %s (%s)"
        (List.length voters)
        (List.length st.st_children)
        (Signal.action_to_string action)
        (match st.st_policy with
         | Unanimous -> "unanimous"
         | Majority -> "majority"
         | Any -> "any")
  in
  let sig_ = {
    Signal.ts = candle.Candle.ts;
    instrument;
    action;
    strength;
    stop_loss = None;
    take_profit = None;
    reason;
  } in
  { st_policy = st.st_policy; st_children = children' }, sig_
