(** Strategy registry — the only file that needs editing to add a strategy
    to the UI/CLI pickers. Each entry knows how to build a default instance
    and how to describe its tunable parameters. *)

type param =
  | Int of int
  | Float of float
  | Bool of bool

type spec = {
  name : string;
  params : (string * param) list;
  build : (string * param) list -> Strategy.t;
}

let get_int p k d = match List.assoc_opt k p with
  | Some (Int n) -> n | _ -> d
let get_float p k d = match List.assoc_opt k p with
  | Some (Float f) -> f | Some (Int n) -> float_of_int n | _ -> d
let get_bool p k d = match List.assoc_opt k p with
  | Some (Bool b) -> b | _ -> d

let specs : spec list = [
  { name = Sma_crossover.name;
    params = [
      "fast", Int 10; "slow", Int 30; "allow_short", Bool false;
    ];
    build = fun p ->
      let params = Sma_crossover.{
        fast = get_int p "fast" 10;
        slow = get_int p "slow" 30;
        allow_short = get_bool p "allow_short" false;
      } in
      Strategy.make (module Sma_crossover) params };

  { name = Rsi_mean_reversion.name;
    params = [
      "period", Int 14;
      "lower", Float 30.0; "upper", Float 70.0;
      "exit_long", Float 50.0; "exit_short", Float 50.0;
      "allow_short", Bool false;
    ];
    build = fun p ->
      let params = Rsi_mean_reversion.{
        period = get_int p "period" 14;
        lower = get_float p "lower" 30.0;
        upper = get_float p "upper" 70.0;
        exit_long = get_float p "exit_long" 50.0;
        exit_short = get_float p "exit_short" 50.0;
        allow_short = get_bool p "allow_short" false;
      } in
      Strategy.make (module Rsi_mean_reversion) params };

  { name = Macd_momentum.name;
    params = [
      "fast", Int 12; "slow", Int 26; "signal", Int 9;
      "allow_short", Bool false;
    ];
    build = fun p ->
      let params = Macd_momentum.{
        fast = get_int p "fast" 12;
        slow = get_int p "slow" 26;
        signal = get_int p "signal" 9;
        allow_short = get_bool p "allow_short" false;
      } in
      Strategy.make (module Macd_momentum) params };

  { name = Bollinger_breakout.name;
    params = [
      "period", Int 20; "k", Float 2.0; "allow_short", Bool true;
    ];
    build = fun p ->
      let params = Bollinger_breakout.{
        period = get_int p "period" 20;
        k = get_float p "k" 2.0;
        allow_short = get_bool p "allow_short" true;
      } in
      Strategy.make (module Bollinger_breakout) params };
]

(** Build a composite strategy from registry entries. Used by the
    composite spec builder below and available for programmatic use. *)
let build_child name params =
  match List.find_opt (fun s -> s.name = name) specs with
  | Some s -> s.build params
  | None -> invalid_arg ("Registry: unknown child strategy " ^ name)

let composite_specs : spec list = [
  { name = "Composite_SMA_RSI";
    params = [ "policy", Int 1 ];
    build = fun p ->
      let policy = match get_int p "policy" 1 with
        | 0 -> Composite.Unanimous
        | 2 -> Composite.Any
        | _ -> Majority
      in
      let children = [
        build_child Sma_crossover.name [];
        build_child Rsi_mean_reversion.name [];
      ] in
      Strategy.make (module Composite)
        Composite.{ policy; children } };

  { name = "Composite_SMA_MACD";
    params = [ "policy", Int 1 ];
    build = fun p ->
      let policy = match get_int p "policy" 1 with
        | 0 -> Composite.Unanimous
        | 2 -> Composite.Any
        | _ -> Majority
      in
      let children = [
        build_child Sma_crossover.name [];
        build_child Macd_momentum.name [];
      ] in
      Strategy.make (module Composite)
        Composite.{ policy; children } };

  { name = "Composite_All";
    params = [ "policy", Int 1 ];
    build = fun p ->
      let policy = match get_int p "policy" 1 with
        | 0 -> Composite.Unanimous
        | 2 -> Composite.Any
        | _ -> Majority
      in
      let children = [
        build_child Sma_crossover.name [];
        build_child Rsi_mean_reversion.name [];
        build_child Macd_momentum.name [];
        build_child Bollinger_breakout.name [];
      ] in
      Strategy.make (module Composite)
        Composite.{ policy; children } };
]

let all_specs = specs @ composite_specs

let find n = List.find_opt (fun s -> s.name = n) all_specs
let names () = List.map (fun s -> s.name) all_specs
