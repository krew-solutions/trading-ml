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

type feed = { mutable refs : int; stop : unit -> unit }
(** A live generator fiber for one instrument: a daemon that ticks a
    random walk, emitting one closed candle plus its reconstructed
    public-tape prints per tick. Refcounted so bar and public-trade
    subscriptions for the same instrument share one fiber (one walk
    feeds both). [stop] cancels the daemon when the last subscriber
    drops. *)

module InstrMap = Map.Make (Instrument)

type t = {
  start_ts : int64;
  start_price : float;
  (* Per-instance RNG so concurrent clients don't race on global
     state and so tests can seed it deterministically. *)
  wobble : unit -> float;
  mutex : Eio.Mutex.t;
  (* Live-feed context captured at [start_live_feed]: the switch the
     generator fibers run under, the clock to sleep on, and the sink
     every generated event flows through. None until the feed starts —
     [subscribe] before that is a no-op (no live mode requested). *)
  mutable live :
    (Eio.Switch.t * float Eio.Time.clock_ty Eio.Std.r * (Broker.event -> unit)) option;
  mutable feeds : feed InstrMap.t;
}

let make ?(start_ts = 1_704_067_200L) ?(start_price = 100.0) () =
  let state = Random.State.make_self_init () in
  {
    start_ts;
    start_price;
    wobble = (fun () -> Random.State.float state 1.0);
    mutex = Eio.Mutex.create ();
    live = None;
    feeds = InstrMap.empty;
  }

(** Demo cadence: one candle every [tick_seconds] of wall time,
    independent of the bar's nominal timeframe. Short so an M1 footprint
    seals within a couple of ticks when eyeballing the UI; the candle's
    own [ts] still advances by the real timeframe period so the chart's
    time axis stays sane. *)
let tick_seconds = 2.0

let prints_per_candle = 10

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
    For synthetic order simulation, run the paper_broker BC against
    the bus: it consumes [broker.bar-updated] (published by this
    adapter through the broker BC's factory) and owns the order
    matching. Calling order methods directly on this adapter raises
    so the misconfiguration surfaces at the first call instead of
    silently returning empty lists. *)
let unsupported fn =
  failwith
    (Printf.sprintf
       "synthetic broker does not support %s — orders flow through the paper_broker BC \
        on the bus, not through the data source"
       fn)

let place_order _ ~placement_id:_ ~instrument:_ ~side:_ ~quantity:_ ~kind:_ ~tif:_ =
  unsupported "place_order"

let cancel_order _ ~placement_id:_ = unsupported "cancel_order"

let get_order _ ~placement_id:_ = unsupported "get_order"

let get_trades _ ~placement_id:_ = unsupported "get_trades"

(** Live-feed surface: today's synthetic adapter is a sync REST
    source only. [start_live_feed] / [subscribe] / [unsubscribe]
    are no-ops because there is no async stream to drive — the
    backtest harness in [bin/main.ml] still drives bars through
    the bus directly.

    Live mode: [start_live_feed] captures the switch, clock and event
    sink; [subscribe] then forks a per-instrument generator daemon that
    ticks a random walk, emitting one closed [Bar_updated] candle plus
    its reconstructed [Public_trade_printed] prints each tick. Bars and
    public-trades for one instrument share a single daemon (one walk
    drives both), refcounted so the fiber lives exactly as long as some
    subscription holds the instrument. This makes synthetic symmetric
    with Finam / BCS through the port — [serve --broker synthetic] now
    drives both the bar stream and the footprint tape with no special
    casing in the composition root. A replay fiber (from a recorded
    tape) is the next planned source on the same seam. *)

(** One generator loop for [instrument]: sleeps [tick_seconds], emits a
    fresh closed candle and its reconstructed prints through [on_event],
    repeats until [stopped] is set (by the last unsubscribe) or the host
    switch is cancelled. The walk state (price, ts) is loop-local; [ts]
    advances by the real timeframe period each tick so each candle lands
    in a new bucket and the footprint of the previous one seals. *)
let run_feed t ~clock ~on_event ~instrument ~timeframe ~(stopped : bool ref) : unit =
  let tf_seconds = Timeframe.to_seconds timeframe in
  let rng = Random.State.make_self_init () in
  let rec loop price ts =
    if !stopped then ()
    else begin
      Eio.Time.sleep clock tick_seconds;
      let drift = (Random.State.float rng 2.0 -. 1.0) *. 0.5 in
      let close = Float.max 1.0 (price +. drift) in
      let high = Float.max price close +. Random.State.float rng 0.5 in
      let low = Float.max 0.5 (Float.min price close -. Random.State.float rng 0.5) in
      let volume = 100.0 +. Random.State.float rng 1000.0 in
      let candle =
        Candle.make ~ts ~open_:(Decimal.of_float price) ~high:(Decimal.of_float high)
          ~low:(Decimal.of_float low) ~close:(Decimal.of_float close)
          ~volume:(Decimal.of_float volume)
      in
      on_event
        (Broker.Bar_updated
           {
             Broker_domain.Remote_broker.Events.Bar_updated.instrument;
             timeframe;
             candle;
           });
      List.iter
        (fun pt -> on_event (Broker.Public_trade_printed pt))
        (Trade_generator.generate ~instrument ~candle ~tf_seconds ~n:prints_per_candle);
      loop close (Int64.add ts (Int64.of_int tf_seconds))
    end
  in
  loop t.start_price t.start_ts

let start_live_feed t ~sw ~env ~on_event : unit =
  let clock = Eio.Stdenv.clock env in
  t.live <- Some (sw, clock, on_event)

(* The instrument a request concerns — both subscription kinds drive the
   same per-instrument feed. *)
let request_instrument : Broker.request -> Instrument.t = function
  | Subscribe_bars { instrument; _ } -> instrument
  | Subscribe_public_trades { instrument } -> instrument

let request_timeframe : Broker.request -> Timeframe.t = function
  | Subscribe_bars { timeframe; _ } -> timeframe
  | Subscribe_public_trades _ -> Timeframe.M1

let subscribe t (request : Broker.request) : unit =
  match t.live with
  | None ->
      (* No live mode requested (e.g. a backtest that drives the bus
         directly). Nothing to start. *)
      ()
  | Some (sw, clock, on_event) ->
      let instrument = request_instrument request in
      let timeframe = request_timeframe request in
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
          match InstrMap.find_opt instrument t.feeds with
          | Some feed -> feed.refs <- feed.refs + 1
          | None ->
              (* First subscriber for this instrument: fork a daemon that
                 runs until [stopped] is set on the last unsubscribe (or
                 the host switch is torn down at shutdown). *)
              let stopped = ref false in
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  (try run_feed t ~clock ~on_event ~instrument ~timeframe ~stopped
                   with e ->
                     Log.warn "[synthetic] feed for %s stopped: %s"
                       (Instrument.to_qualified instrument)
                       (Printexc.to_string e));
                  `Stop_daemon);
              t.feeds <-
                InstrMap.add instrument
                  { refs = 1; stop = (fun () -> stopped := true) }
                  t.feeds)

let unsubscribe t (request : Broker.request) : unit =
  let instrument = request_instrument request in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match InstrMap.find_opt instrument t.feeds with
      | None -> ()
      | Some feed ->
          feed.refs <- feed.refs - 1;
          if feed.refs <= 0 then begin
            t.feeds <- InstrMap.remove instrument t.feeds;
            feed.stop ()
          end)

let as_broker (t : t) : Broker.client =
  Broker.make
    (module struct
      type nonrec t = t

      let name = name
      let bars = bars
      let venues = venues
      let place_order = place_order
      let cancel_order = cancel_order
      let get_order = get_order
      let get_trades = get_trades
      let start_live_feed = start_live_feed
      let subscribe = subscribe
      let unsubscribe = unsubscribe
    end)
    t
