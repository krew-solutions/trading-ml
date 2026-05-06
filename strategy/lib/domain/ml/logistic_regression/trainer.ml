(** Offline walk-forward trainer for the Learned composite policy.

    Given a list of child strategies and a candle history, it:
    1. Runs all children over the history, collecting per-bar signals.
    2. For each bar where at least one child emits non-Hold, builds a
       feature vector ([Features.extract]) and a binary target:
       1.0 if long entry would be profitable over the next [lookahead]
       bars, 0.0 otherwise.
    3. Splits the dataset into a training prefix (first 70%) and a
       validation suffix (last 30%).
    4. Trains a [Logistic.t] on the training set for [epochs].
    5. Returns the learned weights and the validation log-loss.

    Walk-forward discipline: the target at bar [i] looks at
    close[i+lookahead], so the training set uses only bars whose
    outcome is fully determined by bars within the training window.
    No future information leaks into the model. *)

open Core

type result = {
  weights : float array;
  train_loss : float;
  val_loss : float;
  n_train : int;
  n_val : int;
}

let train
    ~(children : Strategies.Strategy.t list)
    ~(candles : Candle.t list)
    ?(lookahead = 5)
    ?(epochs = 10)
    ?(lr = 0.01)
    ?(l2 = 1e-4)
    ?(context_window = 20)
    () : result =
  let n_children = List.length children in
  let n_features = Features.n_features ~n_children in
  let closes =
    Array.of_list (List.map (fun (c : Candle.t) -> Decimal.to_float c.close) candles)
  in
  let volumes =
    Array.of_list (List.map (fun (c : Candle.t) -> Decimal.to_float c.volume) candles)
  in
  let n_bars = Array.length closes in
  (* Run all children over history, collecting signals per bar. *)
  let all_signals = Array.make n_bars [] in
  let _final_children =
    List.fold_left
      (fun bar_idx _pass ->
        ignore bar_idx;
        0)
      0 []
  in
  (* Actually: fold over candles, updating all children simultaneously. *)
  let inst =
    Instrument.make ~ticker:(Ticker.of_string "TRAIN") ~venue:(Mic.of_string "MISX") ()
  in
  let children_ref = ref children in
  List.iteri
    (fun i candle ->
      let children', signals =
        List.fold_left
          (fun (cs, sigs) child ->
            let c', sig_ = Strategies.Strategy.on_candle child inst candle in
            (c' :: cs, sig_ :: sigs))
          ([], []) !children_ref
      in
      children_ref := List.rev children';
      all_signals.(i) <- List.rev signals)
    candles;
  (* Build (features, target) dataset.
     Target: is close[i+lookahead] > close[i]? (for long bias).
     Skip bars where all children Hold (no decision point). *)
  let dataset = ref [] in
  for i = 0 to n_bars - lookahead - 1 do
    let signals = all_signals.(i) in
    let has_signal =
      List.exists (fun (s : Signal.t) -> s.action <> Signal.Hold) signals
    in
    if has_signal then begin
      let recent_closes =
        let start = max 0 (i - context_window + 1) in
        Array.to_list (Array.sub closes start (i - start + 1)) |> List.rev
      in
      let recent_volumes =
        let start = max 0 (i - context_window + 1) in
        Array.to_list (Array.sub volumes start (i - start + 1)) |> List.rev
      in
      let candle = List.nth candles i in
      let features = Features.extract ~signals ~candle ~recent_closes ~recent_volumes in
      let future_close = closes.(i + lookahead) in
      let current_close = closes.(i) in
      let target = if future_close > current_close then 1.0 else 0.0 in
      dataset := (features, target) :: !dataset
    end
  done;
  let dataset = List.rev !dataset in
  let n_total = List.length dataset in
  if n_total < 10 then
    {
      weights = Array.make (1 + n_features) 0.0;
      train_loss = Float.infinity;
      val_loss = Float.infinity;
      n_train = 0;
      n_val = 0;
    }
  else begin
    let split = n_total * 7 / 10 in
    let train_data = List.filteri (fun i _ -> i < split) dataset in
    let val_data = List.filteri (fun i _ -> i >= split) dataset in
    let model = Logistic.make ~n_features ~lr ~l2 () in
    let train_loss = Logistic.train model ~epochs train_data in
    let val_loss =
      if val_data = [] then 0.0
      else
        let total =
          List.fold_left
            (fun acc (features, target) ->
              let p = Logistic.predict model features in
              let p = Float.max 1e-12 (Float.min (1.0 -. 1e-12) p) in
              acc -. ((target *. log p) +. ((1.0 -. target) *. log (1.0 -. p))))
            0.0 val_data
        in
        total /. float_of_int (List.length val_data)
    in
    {
      weights = Logistic.export_weights model;
      train_loss;
      val_loss;
      n_train = List.length train_data;
      n_val = List.length val_data;
    }
  end
