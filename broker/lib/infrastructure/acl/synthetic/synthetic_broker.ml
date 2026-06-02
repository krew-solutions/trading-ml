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
  now : unit -> int64;
      (** Composition-root clock (Unix live / Virtual backtest). Anchors
          both the bar history and the live feed to one timeline so the
          candle series and the footprint tape share an X axis — their
          right edges land on the same "current" bucket. *)
  mutex : Eio.Mutex.t;
  (* Live-feed context captured at [start_live_feed]: the switch the
     generator fibers run under, the clock to sleep on, and the sink
     every generated event flows through. None until the feed starts —
     [subscribe] before that is a no-op (no live mode requested). *)
  mutable live :
    (Eio.Switch.t * float Eio.Time.clock_ty Eio.Std.r * (Broker.event -> unit)) option;
  mutable feeds : feed InstrMap.t;
}

let make ~now () =
  { now; mutex = Eio.Mutex.create (); live = None; feeds = InstrMap.empty }

let prints_per_candle = 10
let name = "synthetic"

(* ---- Deterministic walk indexed by absolute bucket number ----------
   The price at bucket [k] (= ts / tf_seconds) is a pure function of [k]
   and [tf_seconds], so the bar history ([bars]) and the live feed
   ([run_feed]) agree on every bucket without sharing mutable state:
   [bars] returns the last n buckets up to "now", the live feed appends
   the next bucket as wall-time crosses its edge, and they join
   seamlessly because both evaluate the same function. Re-polling [bars]
   is stable (same k -> same candle) — no jitter between requests. *)

(* Smooth-ish random-ish walk: superposed sines of the bucket index plus
   a hash-based jitter, centred near 100. Bounded and continuous in [k]
   so adjacent candles connect (close[k] ≈ open[k+1]). *)
let price_at ~tf_seconds k =
  let kf = Int64.to_float k in
  let scale = 1.0 +. (float_of_int tf_seconds /. 600.0) in
  let trend = 100.0 +. (10.0 *. sin (kf /. 50.0)) +. (4.0 *. sin (kf /. 11.0)) in
  let jitter =
    let h = Int64.to_int (Int64.logand (Int64.mul k 2654435761L) 0xffffL) in
    float_of_int (h - 0x8000) /. 32768.0 *. 1.5 *. scale
  in
  Float.max 1.0 (trend +. jitter)

(* Candle for absolute bucket [k]: open = price_at k, close = price_at
   (k+1) (so it joins the next bar), high/low bracket them with a small
   deterministic wick. Volume from the same hash so it's stable. *)
let candle_at ~tf_seconds k : Candle.t =
  let ts = Int64.mul k (Int64.of_int tf_seconds) in
  let o = price_at ~tf_seconds k and c = price_at ~tf_seconds (Int64.add k 1L) in
  let h64 = Int64.to_int (Int64.logand (Int64.mul k 40503L) 0xffffL) in
  let wick = float_of_int h64 /. 65535.0 *. 0.6 in
  let high = Float.max o c +. wick in
  let low = Float.max 0.5 (Float.min o c -. wick) in
  let volume = 200.0 +. (float_of_int (Int64.to_int (Int64.logand k 0x3ffL)) *. 2.0) in
  Candle.make ~ts ~open_:(Decimal.of_float o) ~high:(Decimal.of_float high)
    ~low:(Decimal.of_float low) ~close:(Decimal.of_float c)
    ~volume:(Decimal.of_float volume)

(* The bucket index of the candle currently forming at the clock's now. *)
let current_bucket t ~tf_seconds = Int64.div (t.now ()) (Int64.of_int tf_seconds)

let bars t ~n ~instrument:_ ~timeframe =
  let tf_seconds = Timeframe.to_seconds timeframe in
  let last_k = current_bucket t ~tf_seconds in
  let first_k = Int64.sub last_k (Int64.of_int (max 0 (n - 1))) in
  List.init n (fun i -> candle_at ~tf_seconds (Int64.add first_k (Int64.of_int i)))

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

(* How many closed footprint buckets to backfill at subscribe, so the
   footprint history covers the same recent window the candle chart shows
   (instead of starting empty and trailing). Capped — footprint history is
   transitional in-memory and this is just enough to fill the view. *)
let backfill_buckets = 300

(** Generator loop for [instrument], anchored to the injected clock so it
    stays on the SAME timeline as [bars]:

    1. Backfill — replay the last [backfill_buckets] CLOSED buckets
       (everything strictly before the forming bucket) as Bar_updated +
       prints, so a footprint exists for each and the footprint series
       immediately spans the candle window. Each [candle_at k] equals
       what [bars] returns for the same k, so the two series agree
       point-for-point.
    2. Live — wait until wall-time crosses the next bucket edge, then
       emit that now-closed bucket. The footprint of bucket k seals when
       the first print of bucket k+1 arrives (lazy close), so emitting
       each newly-closed bucket advances the footprint right edge in
       lockstep with real time, matching the candles.

    Stops when [stopped] is set (last unsubscribe) or the host switch is
    torn down. *)
let run_feed t ~clock ~on_event ~instrument ~timeframe ~(stopped : bool ref) : unit =
  let tf_seconds = Timeframe.to_seconds timeframe in
  let tf64 = Int64.of_int tf_seconds in
  let emit k =
    let candle = candle_at ~tf_seconds k in
    on_event
      (Broker.Bar_updated
         { Broker_domain.Remote_broker.Events.Bar_updated.instrument; timeframe; candle });
    List.iter
      (fun pt -> on_event (Broker.Public_trade_printed pt))
      (Trade_generator.generate ~instrument ~candle ~tf_seconds ~n:prints_per_candle)
  in
  (* 1. Backfill closed buckets [forming - backfill .. forming - 1]. *)
  let forming = current_bucket t ~tf_seconds in
  let first = Int64.sub forming (Int64.of_int backfill_buckets) in
  let k = ref first in
  while Int64.compare !k forming < 0 do
    emit !k;
    k := Int64.add !k 1L
  done;
  (* 2. Live: sleep to each next bucket edge, then emit the bucket that
     just closed. [emitted] is the last bucket we've emitted. *)
  let emitted = ref (Int64.sub forming 1L) in
  while not !stopped do
    let now = t.now () in
    let cur = Int64.div now tf64 in
    if Int64.compare cur !emitted > 0 then begin
      (* One or more buckets closed since we last looked; emit them. *)
      let kk = ref (Int64.add !emitted 1L) in
      while Int64.compare !kk cur <= 0 do
        emit !kk;
        kk := Int64.add !kk 1L
      done;
      emitted := cur
    end
    else begin
      (* Sleep until the current bucket's edge (when it will have closed). *)
      let edge = Int64.mul (Int64.add cur 1L) tf64 in
      let dt = Float.max 0.2 (Int64.to_float (Int64.sub edge now)) in
      Eio.Time.sleep clock dt
    end
  done

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
