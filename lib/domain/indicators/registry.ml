(** Runtime registry of indicator factories. Lets the UI list indicators and
    build new ones by name with typed parameters. Adding a new indicator
    means adding one entry here. *)

type param =
  | Int of int
  | Float of float

type spec = {
  name : string;
  params : (string * param) list;
  build : (string * param) list -> Indicator.t;
}

let get_int params k default =
  match List.assoc_opt k params with
  | Some (Int n) -> n
  | _ -> default

let get_float params k default =
  match List.assoc_opt k params with
  | Some (Float f) -> f
  | Some (Int n) -> float_of_int n
  | _ -> default

let specs : spec list = [
  { name = "SMA";
    params = [ "period", Int 20 ];
    build = fun p -> Sma.make ~period:(get_int p "period" 20) };
  { name = "EMA";
    params = [ "period", Int 20 ];
    build = fun p -> Ema.make ~period:(get_int p "period" 20) };
  { name = "WMA";
    params = [ "period", Int 20 ];
    build = fun p -> Wma.make ~period:(get_int p "period" 20) };
  { name = "RSI";
    params = [ "period", Int 14 ];
    build = fun p -> Rsi.make ~period:(get_int p "period" 14) };
  { name = "MACD";
    params = [ "fast", Int 12; "slow", Int 26; "signal", Int 9 ];
    build = fun p ->
      Macd.make
        ~fast:(get_int p "fast" 12)
        ~slow:(get_int p "slow" 26)
        ~signal:(get_int p "signal" 9) () };
  { name = "MACD-Weighted";
    params = [ "fast", Int 12; "slow", Int 26; "signal", Int 9 ];
    build = fun p ->
      Macd_weighted.make
        ~fast:(get_int p "fast" 12)
        ~slow:(get_int p "slow" 26)
        ~signal:(get_int p "signal" 9) () };
  { name = "BollingerBands";
    params = [ "period", Int 20; "k", Float 2.0 ];
    build = fun p ->
      Bollinger.make
        ~period:(get_int p "period" 20)
        ~k:(get_float p "k" 2.0) () };
  { name = "ATR";
    params = [ "period", Int 14 ];
    build = fun p -> Atr.make ~period:(get_int p "period" 14) };
  { name = "OBV";
    params = [];
    build = fun _ -> Obv.make () };
  { name = "A/D";
    params = [];
    build = fun _ -> Ad.make () };
  { name = "ChaikinOscillator";
    params = [ "fast", Int 3; "slow", Int 10 ];
    build = fun p ->
      Chaikin_oscillator.make
        ~fast:(get_int p "fast" 3)
        ~slow:(get_int p "slow" 10) () };
  { name = "Stochastic";
    params = [ "k_period", Int 14; "d_period", Int 3 ];
    build = fun p ->
      Stochastic.make
        ~k_period:(get_int p "k_period" 14)
        ~d_period:(get_int p "d_period" 3) () };
  { name = "MFI";
    params = [ "period", Int 14 ];
    build = fun p -> Mfi.make ~period:(get_int p "period" 14) };
  { name = "CMF";
    params = [ "period", Int 20 ];
    build = fun p -> Cmf.make ~period:(get_int p "period" 20) };
  { name = "CVI";
    params = [ "period", Int 10 ];
    build = fun p -> Cvi.make ~period:(get_int p "period" 10) };
  { name = "CVD";
    params = [];
    build = fun _ -> Cvd.make () };
  { name = "Volume";
    params = [];
    build = fun _ -> Volume.make () };
  { name = "VolumeMA";
    params = [ "period", Int 20 ];
    build = fun p -> Volume_ma.make ~period:(get_int p "period" 20) };
]

let find name = List.find_opt (fun s -> s.name = name) specs
let names () = List.map (fun s -> s.name) specs
