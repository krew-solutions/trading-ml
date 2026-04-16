(** Shared fixtures for strategy tests. A strategy is a pure state
    machine [state -> Candle.t -> state * Signal.t] — we stream a
    canned price series through it and collect the emitted actions. *)

open Core

let candle ?(volume = 1.0) close =
  let p = Decimal.of_float close in
  Candle.make ~ts:0L
    ~open_:p ~high:p ~low:p ~close:p
    ~volume:(Decimal.of_float volume)

(** Build a candle with an explicit timestamp so strategies that depend
    on ts ordering (like poll-diffing) see a monotonic stream. *)
let ts_candle ~ts close =
  let p = Decimal.of_float close in
  Candle.make ~ts:(Int64.of_int ts)
    ~open_:p ~high:p ~low:p ~close:p ~volume:(Decimal.of_int 1)

let inst = Instrument.make
  ~ticker:(Ticker.of_string "SBER")
  ~venue:(Mic.of_string "MISX") ()

(** Fold a price series through a strategy, collecting the action at
    every step. Returns the list of actions in the same order as the
    input candles. *)
let actions_from_prices (strat : Strategies.Strategy.t) prices =
  let _, acts =
    List.fold_left (fun (s, acc) (i, price) ->
      let c = ts_candle ~ts:i price in
      let s', sig_ = Strategies.Strategy.on_candle s inst c in
      s', sig_.Signal.action :: acc)
      (strat, []) (List.mapi (fun i p -> i, p) prices)
  in
  List.rev acts

(** True if [acts] contains [target] at any position. *)
let contains (target : Signal.action) acts =
  List.exists (fun a -> a = target) acts
