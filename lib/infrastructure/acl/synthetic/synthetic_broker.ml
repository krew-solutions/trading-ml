(** Synthetic broker adapter. Implements {!Broker.S} by generating a
    deterministic random-walk via {!Generator}, with an intrabar
    wobble applied to the trailing candle on each [bars] call so that
    polling consumers (SSE stream, UI) see visible ticks without the
    rest of the history rewriting itself.

    Its role is symmetric to Finam and BCS — a legitimate
    [Broker.client] the inbound layer routes to without
    special-casing. Keeping "no real broker configured" as an
    ordinary adapter choice avoids fake data masking errors in the
    live paths, and lets strategies / backtests run against a stable
    data source regardless of broker availability. *)

open Core

type t = {
  start_ts : int64;
  start_price : float;
  (* Per-instance RNG so concurrent clients don't race on global
     state and so tests can seed it deterministically. *)
  wobble : unit -> float;
}

let make ?(start_ts = 1_704_067_200L) ?(start_price = 100.0) () =
  let state = Random.State.make_self_init () in
  { start_ts; start_price; wobble = (fun () -> Random.State.float state 1.0) }

let name = "synthetic"

(** Drift the trailing bar's close/high/low/volume a little so poll
    consumers observe the chart moving. Only the tail is touched —
    the historical body stays identical across calls, preserving
    backtest determinism. *)
let wobble_last ~rng candles =
  match List.rev candles with
  | [] -> []
  | last :: rest_rev ->
      let f = Decimal.to_float last.Candle.close in
      let drift = ((rng () *. 2.0) -. 1.0) *. 0.3 in
      let close = Float.max 1.0 (f +. drift) in
      let high = Float.max (Decimal.to_float last.high) close in
      let low = Float.min (Decimal.to_float last.low) close in
      let updated =
        Candle.make ~ts:last.ts ~open_:last.open_ ~high:(Decimal.of_float high)
          ~low:(Decimal.of_float low) ~close:(Decimal.of_float close)
          ~volume:(Decimal.add last.volume (Decimal.of_int 100))
      in
      List.rev (updated :: rest_rev)

let bars t ~n ~instrument:_ ~timeframe =
  Generator.generate ~n ~start_ts:t.start_ts
    ~tf_seconds:(Timeframe.to_seconds timeframe)
    ~start_price:t.start_price
  |> wobble_last ~rng:t.wobble

(** Synthetic has no real venue list; surface a single placeholder so
    the UI dropdown still renders. Using MOEX keeps the qualified
    symbol [SBER@MISX] working for all downstream logic. *)
let venues _ = [ Mic.of_string "MISX" ]

(** Synthetic is a data-only source — order execution is out of scope.
    For synthetic order simulation, wrap this adapter in
    {!Paper.Paper_broker}: it delegates market data here and owns the
    order book itself. Calling order methods directly raises so the
    misconfiguration surfaces at the first call instead of silently
    returning empty lists. *)
let unsupported fn =
  failwith
    (Printf.sprintf
       "synthetic broker does not support %s — wrap it in Paper.Paper_broker for order \
        simulation"
       fn)

let place_order _ ~instrument:_ ~side:_ ~quantity:_ ~kind:_ ~tif:_ ~client_order_id:_ =
  unsupported "place_order"
let get_orders _ = unsupported "get_orders"
let get_order _ ~client_order_id:_ = unsupported "get_order"
let cancel_order _ ~client_order_id:_ = unsupported "cancel_order"
let get_executions _ ~client_order_id:_ = unsupported "get_executions"

(** Synthetic has no wire format so any fresh string works. Use a
    dashed UUIDv4 for log readability; nothing else depends on the
    shape. *)
let generate_client_order_id _ =
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string

let as_broker (t : t) : Broker.client =
  Broker.make
    (module struct
      type nonrec t = t
      let name = name
      let bars = bars
      let venues = venues
      let place_order = place_order
      let get_orders = get_orders
      let get_order = get_order
      let cancel_order = cancel_order
      let get_executions = get_executions
      let generate_client_order_id = generate_client_order_id
    end)
    t
