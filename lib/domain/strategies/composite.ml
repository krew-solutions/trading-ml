(** Composite strategy: combines N child strategies under a voting
    policy. Each child runs independently; their signals are
    aggregated per bar into a single output.

    This module itself implements [Strategy.S], so a composite is
    indistinguishable from a leaf strategy — it can be backtested,
    registered, or nested into another composite. *)

open Core

type predictor =
  signals:Signal.t list ->
  candle:Candle.t ->
  recent_closes:float list ->
  recent_volumes:float list ->
  float

type policy =
  | Unanimous
  | Majority
  | Any
  | Adaptive of { window : int }
  | Learned of { predict : predictor; threshold : float }

type params = { policy : policy; children : Strategy.t list }

type child_track = {
  strategy : Strategy.t;
  position : [ `Flat | `Long of float | `Short of float ];
  returns : float list;  (** most recent first, capped at [window] *)
  window : int;
}
(** Per-child position tracker for Adaptive mode. Tracks a virtual
    position and accumulates a rolling window of realized returns,
    from which the Sharpe ratio is derived. *)

type state = {
  st_policy : policy;
  st_children : child_track list;
  st_recent_closes : float list;
  st_recent_volumes : float list;
  st_context_window : int;
}

let name = "Composite"

let default_params = { policy = Majority; children = [] }

let init_track ~window strat =
  { strategy = strat; position = `Flat; returns = []; window }

let window_of_policy = function
  | Adaptive { window } -> window
  | _ -> 50

let init p =
  let w = window_of_policy p.policy in
  {
    st_policy = p.policy;
    st_children = List.map (init_track ~window:w) p.children;
    st_recent_closes = [];
    st_recent_volumes = [];
    st_context_window = 20;
  }

(** Push a return into the rolling window, capped at [window]. *)
let push_return t r =
  let returns = r :: t.returns in
  let returns =
    if List.length returns > t.window then List.filteri (fun i _ -> i < t.window) returns
    else returns
  in
  { t with returns }

(** Update virtual position after a signal; realize return on close. *)
let track_signal (t : child_track) (sig_ : Signal.t) ~close : child_track =
  match (sig_.action, t.position) with
  | Enter_long, `Flat -> { t with position = `Long close }
  | Enter_short, `Flat -> { t with position = `Short close }
  | Exit_long, `Long entry ->
      let ret = (close -. entry) /. (Float.abs entry +. 1e-9) in
      push_return { t with position = `Flat } ret
  | Exit_short, `Short entry ->
      let ret = (entry -. close) /. (Float.abs entry +. 1e-9) in
      push_return { t with position = `Flat } ret
  | Enter_short, `Long entry ->
      let ret = (close -. entry) /. (Float.abs entry +. 1e-9) in
      let t = push_return { t with position = `Flat } ret in
      { t with position = `Short close }
  | Enter_long, `Short entry ->
      let ret = (entry -. close) /. (Float.abs entry +. 1e-9) in
      let t = push_return { t with position = `Flat } ret in
      { t with position = `Long close }
  | _ -> t

(** Annualized Sharpe ratio from a list of per-bar returns.
    Returns 0.0 when there are fewer than 2 data points. *)
let sharpe returns =
  let n = List.length returns in
  if n < 2 then 0.0
  else
    let mean = List.fold_left ( +. ) 0.0 returns /. float_of_int n in
    let var =
      List.fold_left (fun acc r -> acc +. ((r -. mean) *. (r -. mean))) 0.0 returns
      /. float_of_int (n - 1)
    in
    let std = Float.sqrt var in
    if std < 1e-12 then 0.0 else mean /. std

type vote_entry = { action : Signal.action; count : int; avg_strength : float }
(** Per-action vote: count of voters + averaged strength. *)

let tally (signals : Signal.t list) : vote_entry list =
  let count_for action =
    let voters = List.filter (fun (s : Signal.t) -> s.action = action) signals in
    match voters with
    | [] -> None
    | _ ->
        let avg =
          List.fold_left (fun acc (s : Signal.t) -> acc +. s.strength) 0.0 voters
          /. float_of_int (List.length voters)
        in
        Some { action; count = List.length voters; avg_strength = avg }
  in
  List.filter_map Fun.id
    [
      count_for Signal.Exit_long;
      count_for Signal.Exit_short;
      count_for Signal.Enter_long;
      count_for Signal.Enter_short;
    ]

(** Weighted tally for Adaptive: each child's signal is scaled by
    its Sharpe-derived weight. Actions with total weight > 0.5 win. *)
let weighted_tally (children : child_track list) (signals : Signal.t list) :
    (Signal.action * float) option =
  let sharpes = List.map (fun c -> Float.max 0.0 (sharpe c.returns)) children in
  let total_sharpe = List.fold_left ( +. ) 0.0 sharpes in
  let weights =
    if total_sharpe < 1e-12 then
      List.map (fun _ -> 1.0 /. float_of_int (List.length children)) children
    else List.map (fun s -> s /. total_sharpe) sharpes
  in
  let weighted =
    List.map2 (fun w (s : Signal.t) -> (s.action, w, s.strength)) weights signals
  in
  let non_hold = List.filter (fun (a, _, _) -> a <> Signal.Hold) weighted in
  let is_exit a = a = Signal.Exit_long || a = Signal.Exit_short in
  let exits = List.filter (fun (a, _, _) -> is_exit a) non_hold in
  let candidates = if exits <> [] then exits else non_hold in
  let actions = List.sort_uniq compare (List.map (fun (a, _, _) -> a) candidates) in
  let scored =
    List.map
      (fun action ->
        let voters = List.filter (fun (a, _, _) -> a = action) candidates in
        let total_w = List.fold_left (fun acc (_, w, _) -> acc +. w) 0.0 voters in
        let avg_str =
          if total_w < 1e-12 then 0.0
          else List.fold_left (fun acc (_, w, s) -> acc +. (w *. s)) 0.0 voters /. total_w
        in
        (action, total_w, avg_str))
      actions
  in
  let best =
    List.fold_left
      (fun best (a, w, s) ->
        match best with
        | None -> Some (a, w, s)
        | Some (_, bw, _) -> if w > bw then Some (a, w, s) else best)
      None scored
  in
  match best with
  | Some (action, weight, strength) when weight > 0.3 -> Some (action, strength)
  | _ -> None

let pick_winner ~policy ~total (votes : vote_entry list) : (Signal.action * float) option
    =
  if total = 0 then None
  else
    let is_exit a = a = Signal.Exit_long || a = Signal.Exit_short in
    let exits = List.filter (fun v -> is_exit v.action) votes in
    let candidates = if exits <> [] then exits else votes in
    let best =
      List.fold_left
        (fun best v ->
          match best with
          | None -> Some v
          | Some b -> if v.count > b.count then Some v else Some b)
        None candidates
    in
    match best with
    | None -> None
    | Some v ->
        let passes =
          match policy with
          | Unanimous -> v.count = total
          | Majority -> v.count * 2 > total
          | Any -> v.count >= 1
          | Adaptive _ | Learned _ -> true
        in
        if passes then Some (v.action, v.avg_strength) else None

(** Maintain a bounded list of recent values (most recent first). *)
let push_recent ~cap v xs =
  let xs = v :: xs in
  if List.length xs > cap then List.filteri (fun i _ -> i < cap) xs else xs

let learned_decide ~predict ~threshold ~signals ~candle ~recent_closes ~recent_volumes :
    Signal.action * float =
  let p = predict ~signals ~candle ~recent_closes ~recent_volumes in
  if p > threshold then (Signal.Enter_long, p)
  else if p < 1.0 -. threshold then (Signal.Enter_short, 1.0 -. p)
  else (Signal.Hold, 0.0)

let on_candle st instrument candle =
  let close = Decimal.to_float candle.Candle.close in
  let volume = Decimal.to_float candle.Candle.volume in
  let recent_closes = push_recent ~cap:st.st_context_window close st.st_recent_closes in
  let recent_volumes =
    push_recent ~cap:st.st_context_window volume st.st_recent_volumes
  in
  let children', signals =
    List.fold_left
      (fun (cs, sigs) (ct : child_track) ->
        let strat', sig_ = Strategy.on_candle ct.strategy instrument candle in
        let ct' = track_signal { ct with strategy = strat' } sig_ ~close in
        (ct' :: cs, sig_ :: sigs))
      ([], []) st.st_children
  in
  let children' = List.rev children' in
  let signals = List.rev signals in
  let action, strength =
    match st.st_policy with
    | Learned { predict; threshold } ->
        learned_decide ~predict ~threshold ~signals ~candle ~recent_closes ~recent_volumes
    | Adaptive _ -> (
        match weighted_tally children' signals with
        | Some (a, s) -> (a, s)
        | None -> (Signal.Hold, 0.0))
    | policy -> (
        let non_hold =
          List.filter (fun (s : Signal.t) -> s.action <> Signal.Hold) signals
        in
        let total =
          match policy with
          | Unanimous | Majority -> List.length signals
          | Any | Adaptive _ | Learned _ -> List.length non_hold
        in
        let votes = tally non_hold in
        match pick_winner ~policy ~total votes with
        | Some (a, s) -> (a, s)
        | None -> (Signal.Hold, 0.0))
  in
  let reason =
    if action = Signal.Hold then ""
    else
      let policy_name =
        match st.st_policy with
        | Unanimous -> "unanimous"
        | Majority -> "majority"
        | Any -> "any"
        | Adaptive _ -> "adaptive"
        | Learned _ -> "learned"
      in
      let n_children = List.length st.st_children in
      let n_voters =
        List.length (List.filter (fun (s : Signal.t) -> s.action = action) signals)
      in
      Printf.sprintf "%d/%d %s (%s, p=%.2f)" n_voters n_children
        (Signal.action_to_string action)
        policy_name strength
  in
  let sig_ =
    {
      Signal.ts = candle.Candle.ts;
      instrument;
      action;
      strength;
      stop_loss = None;
      take_profit = None;
      reason;
    }
  in
  ( {
      st_policy = st.st_policy;
      st_children = children';
      st_recent_closes = recent_closes;
      st_recent_volumes = recent_volumes;
      st_context_window = st.st_context_window;
    },
    sig_ )
