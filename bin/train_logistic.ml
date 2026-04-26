(** [train-logistic] — offline trainer for the logistic gate of
    [Strategies.Composite.Learned].

    Pulls historical bars from a broker, replays a configurable
    list of child strategies over them, derives labels from
    forward returns, and fits a logistic classifier via
    [Logistic_regression.Trainer.train]. The resulting weights
    are written as JSON suitable for [Logistic.of_file] at
    deploy time.

    Unlike the GBT pipeline (Python + CSV + text-dump), logistic
    training is pure OCaml — this binary is the whole loop. See
    [docs/howto/ml/logistic_regression.md] for how to use the
    output weights in a live-engine / backtest setup.

    Children are specified by registry names, comma-separated.
    Order matters: the feature vector layout is positional, and
    the weights at deploy time must be fed the same children in
    the same order. *)

open Core
open Broker_boot

let usage () =
  prerr_endline
    {|train-logistic
  --broker finam|bcs --symbol SBER@MISX --output PATH
  --children NAME1,NAME2,...           (registry names, see `trading list`)
  [--timeframe M1|M5|M15|M30|H1|H4|D1] (default H1)
  [--from YYYY-MM-DD]                  (default: --to minus 365 days)
  [--to   YYYY-MM-DD]                  (default: now)
  [--lookahead N]                      (default 5 — bars to label forward)
  [--epochs N]                         (default 10)
  [--lr F]                             (default 0.01)
  [--l2 F]                             (default 1e-4)
  [--context-window N]                 (default 20 — recent bars for vol/vol_ratio)
  [--secret S] [--account A] [--client-id C]  (or matching env vars)|};
  exit 2

let parse_date s =
  let s = if String.contains s 'T' then s else s ^ "T00:00:00Z" in
  Infra_common.Iso8601.parse s

(** Look up each comma-separated child name against the registry
    and build a default-param instance. Fails with a precise error
    pointing at the bad name — silently skipping an unknown would
    shift the feature-vector indices and poison training. *)
let build_children (spec : string) : Strategies.Strategy.t list =
  String.split_on_char ',' spec |> List.map String.trim
  |> List.filter (fun s -> s <> "")
  |> List.map (fun name ->
      match Strategies.Registry.find name with
      | Some s -> s.build []
      | None ->
          Printf.eprintf
            "train-logistic: unknown strategy %S (run `trading list` for the registered \
             set)\n"
            name;
          exit 2)

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let require_arg name =
    match arg_value name args with
    | Some v -> v
    | None ->
        Printf.eprintf "train-logistic: %s is required\n" name;
        usage ()
  in
  let broker_id = require_arg "--broker" in
  let symbol = require_arg "--symbol" in
  let output = require_arg "--output" in
  let children_spec = require_arg "--children" in
  let instrument = Instrument.of_qualified symbol in
  let timeframe =
    match arg_value "--timeframe" args with
    | Some s -> Timeframe.of_string s
    | None -> Timeframe.H1
  in
  let now_ts = Int64.of_float (Unix.gettimeofday ()) in
  let to_ts =
    match arg_value "--to" args with
    | Some s -> parse_date s
    | None -> now_ts
  in
  let from_ts =
    match arg_value "--from" args with
    | Some s -> parse_date s
    | None -> Int64.sub to_ts (Int64.of_int (365 * 86400))
  in
  let lookahead =
    match arg_value "--lookahead" args with
    | Some v -> int_of_string v
    | None -> 5
  in
  let epochs =
    match arg_value "--epochs" args with
    | Some v -> int_of_string v
    | None -> 10
  in
  let lr =
    match arg_value "--lr" args with
    | Some v -> float_of_string v
    | None -> 0.01
  in
  let l2 =
    match arg_value "--l2" args with
    | Some v -> float_of_string v
    | None -> 1e-4
  in
  let context_window =
    match arg_value "--context-window" args with
    | Some v -> int_of_string v
    | None -> 20
  in

  let prefix = broker_env_prefix broker_id in
  let secret =
    match arg_value "--secret" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt (prefix ^ "_SECRET")
  in
  let account =
    match arg_value "--account" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt (prefix ^ "_ACCOUNT_ID")
  in
  let client_id =
    match arg_value "--client-id" args with
    | Some v -> Some v
    | None -> Sys.getenv_opt "BCS_CLIENT_ID"
  in

  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let fetch ~from_ts ~to_ts =
    match broker_id with
    | "finam" -> (
        let secret =
          match secret with
          | Some s -> s
          | None ->
              prerr_endline "finam requires --secret or FINAM_SECRET";
              exit 2
        in
        match open_finam ~env ~secret ~account with
        | Opened_finam { rest; _ } ->
            Finam.Rest.bars rest ~from_ts ~to_ts ~n:9999 ~instrument ~timeframe
        | _ -> assert false)
    | "bcs" -> (
        match open_bcs ~env ~secret ~account ~client_id with
        | Opened_bcs { rest; _ } ->
            Bcs.Rest.bars rest ~from_ts ~to_ts ~n:9999 ~instrument ~timeframe
        | _ -> assert false)
    | other ->
        Printf.eprintf "unknown --broker: %s\n" other;
        exit 2
  in
  let candles = paginate_bars ~fetch ~from_ts ~to_ts in
  Printf.printf "Fetched %d bars from %s (%s)\n%!" (List.length candles) broker_id symbol;
  if candles = [] then exit 0;

  let children = build_children children_spec in
  let child_names = List.map Strategies.Strategy.name children |> String.concat ", " in
  Printf.printf "Children (%d): %s\n%!" (List.length children) child_names;

  let result =
    Logistic_regression.Trainer.train ~children ~candles ~lookahead ~epochs ~lr ~l2
      ~context_window ()
  in
  Printf.printf "Trained: n_train=%d n_val=%d train_loss=%.4f val_loss=%.4f\n%!"
    result.n_train result.n_val result.train_loss result.val_loss;

  if result.n_train = 0 then begin
    prerr_endline
      "No training samples collected. Causes: too few candles, children always Hold, or \
       lookahead too large for the history.";
    exit 3
  end;

  (* Persist. Reusing the [Logistic] type's own serialiser means
     [Logistic.of_file output] at deploy time rehydrates the
     model with matching lr / l2, not just weights. *)
  let model = Logistic_regression.Logistic.of_weights ~lr ~l2 result.weights in
  Logistic_regression.Logistic.to_file ~path:output model;
  Printf.printf "Wrote %s (%d weights)\n%!" output (Array.length result.weights)
