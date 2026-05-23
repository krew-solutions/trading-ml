(** Multi-channel SSE registry. One subscriber = one SSE connection,
    multiplexes any number of channels:

    - per-key bar feeds (each [(instrument, timeframe)] is independent);
    - global order broadcast.

    Bar feeds are sourced from the [broker.bar-updated] bus topic.
    A single bus consumer demultiplexes events by
    [(instrument, timeframe)] into per-key feeds, caches the latest
    candles, and fans the framed SSE chunks out to subscribers that
    declared interest in the key. Late SSE joiners receive the
    cache as their seed; the chart UI is expected to pull deeper
    history through [/api/candles] before opening the stream.

    Whether the upstream [(instrument, timeframe)] is actually open
    on a real broker is the broker BC's concern; this registry
    just forwards interest declarations through
    [on_first_subscriber] / [on_last_unsubscriber] so the broker
    can keep its per-key refcount in sync with SSE demand. The
    headless watchlist in the composition root takes the same
    [Broker.subscribe] path and coexists via that refcount. *)

open Core

type event =
  | Bar_updated of Candle.t (* same ts as last cached bar, OHLCV changed *)
  | Bar_closed of Candle.t (* a new bar appeared after the last cached *)

(** Encode to SSE wire format with explicit [event:] field — the
    SSE protocol's native channel mechanism. On the browser side
    [es.addEventListener("bar", ...)] catches only these messages
    and inside the handler the [kind] field discriminates
    [updated] (intra-bar mutation) from [closed] (new bar);
    [symbol] + [timeframe] tell the consumer which feed a single
    multi-feed connection received the event for.

    Bar events for one feed share an ordering domain, so they
    ride one channel and a single sequential consumer on the
    subscriber preserves their order. *)
let encode_event ~instrument ~timeframe : event -> string =
  let key_fields =
    [
      ("symbol", `String (Instrument.to_qualified instrument));
      ("timeframe", `String (Timeframe.to_string timeframe));
    ]
  in
  function
  | Bar_updated c ->
      let j : Yojson.Safe.t =
        `Assoc
          ((("kind", `String "updated") :: key_fields) @ [ ("candle", Api.candle_json c) ])
      in
      "event: bar\ndata: " ^ Yojson.Safe.to_string j ^ "\n\n"
  | Bar_closed c ->
      let j : Yojson.Safe.t =
        `Assoc
          ((("kind", `String "closed") :: key_fields) @ [ ("candle", Api.candle_json c) ])
      in
      "event: bar\ndata: " ^ Yojson.Safe.to_string j ^ "\n\n"

type key = Instrument.t * Timeframe.t

module Key = struct
  type t = key
  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module KMap = Map.Make (Key)
module KSet = Set.Make (Key)

type subscriber = { id : int; queue : string Eio.Stream.t; mutable bar_keys : KSet.t }

type feed = {
  mutable last_candles : Candle.t list;
      (** True while stale bars are being dropped — log once on
      transition to stale, stay silent until a fresh bar arrives. *)
  mutable stale_warned : bool;
}

type lifecycle_hook = instrument:Instrument.t -> timeframe:Timeframe.t -> unit

type t = {
  on_first : lifecycle_hook;
  on_last : lifecycle_hook;
  mutable feeds : feed KMap.t;
  mutable subscribers : subscriber list;
  mutex : Eio.Mutex.t;
  mutable next_id : int;
}

module External_integration_events = Server_external_integration_events
module Bar_updated_ie = External_integration_events.Bar_updated_integration_event
module Bar_updated_ie_handler =
  External_integration_events.Bar_updated_integration_event_handler

(** Intra-bar mutation detector: two bars with the same [ts] are
    considered distinct if their OHLC or volume diverge. *)
let same_bar (a : Candle.t) (b : Candle.t) =
  Int64.equal a.ts b.ts && Decimal.equal a.open_ b.open_ && Decimal.equal a.high b.high
  && Decimal.equal a.low b.low && Decimal.equal a.close b.close
  && Decimal.equal a.volume b.volume

let last = function
  | [] -> None
  | l -> Some (List.nth l (List.length l - 1))

(** Snapshot subscribers interested in [key]. Caller must hold [t.mutex]. *)
let subscribers_of_key t key =
  List.filter (fun s -> KSet.mem key s.bar_keys) t.subscribers

(** Handle one decoded bar event from the bus: update the cached
    candle for [(instrument, timeframe)] and fan the framed SSE
    chunk out to every subscriber that holds the key. No-op when
    no subscriber holds the key (the feed doesn't exist) — this
    happens for keys opened by the headless watchlist but unused
    by any SSE client.

    Monotonicity is enforced upstream at the broker ACL boundary,
    so by the time an event reaches us it is already monotonic
    within its key. We keep a defensive last-ts guard anyway: it
    silences the surprising case of a brand-new SSE feed seeing
    a bar with a [ts] strictly older than something it already
    cached locally (e.g. cache populated by an earlier SSE
    session that this feed inherited), which would still violate
    the chart library's ascending-time invariant on the wire. *)
let dispatch_bar t ~instrument ~timeframe (candle : Candle.t) =
  let key = (instrument, timeframe) in
  let chunk_opt =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        match KMap.find_opt key t.feeds with
        | None -> None
        | Some f -> (
            match last f.last_candles with
            | Some cl when Int64.compare candle.Candle.ts cl.Candle.ts < 0 ->
                if not f.stale_warned then begin
                  f.stale_warned <- true;
                  Log.warn
                    "stream: dropping stale upstream bars for %s/%s (upstream ts=%Ld < \
                     cached tail=%Ld)"
                    (Instrument.to_qualified instrument)
                    (Timeframe.to_string timeframe)
                    candle.ts cl.Candle.ts
                end;
                None
            | last_opt ->
                f.stale_warned <- false;
                let event =
                  match last_opt with
                  | Some cl when Int64.equal cl.Candle.ts candle.ts -> Bar_updated candle
                  | _ -> Bar_closed candle
                in
                let cached =
                  match last_opt with
                  | Some cl when Int64.equal cl.Candle.ts candle.ts -> (
                      match List.rev f.last_candles with
                      | _ :: rest -> List.rev (candle :: rest)
                      | [] -> [ candle ])
                  | _ -> f.last_candles @ [ candle ]
                in
                f.last_candles <- cached;
                Some (encode_event ~instrument ~timeframe event, subscribers_of_key t key)
            ))
  in
  match chunk_opt with
  | None -> ()
  | Some (chunk, subs) -> List.iter (fun s -> Eio.Stream.add s.queue chunk) subs

let handle_bus_event t (ie : Bar_updated_ie.t) : unit =
  Bar_updated_ie_handler.handle ~push:(dispatch_bar t) ie

(** [on_first_subscriber] fires the first time any subscriber declares
    interest in a [(instrument, timeframe)] key — the natural moment
    to forward the subscription to the broker so its upstream feed
    opens. [on_last_unsubscriber] fires when the last interested
    subscriber drops the key, so the broker-side refcount can
    decrement. The composition-root watchlist also calls
    [Broker.subscribe] for keys it cares about, sharing that
    refcount; one path doesn't shut the other one down. *)
let create
    ?(on_first_subscriber : lifecycle_hook = fun ~instrument:_ ~timeframe:_ -> ())
    ?(on_last_unsubscriber : lifecycle_hook = fun ~instrument:_ ~timeframe:_ -> ())
    ~bus
    () =
  let t =
    {
      on_first = on_first_subscriber;
      on_last = on_last_unsubscriber;
      feeds = KMap.empty;
      subscribers = [];
      mutex = Eio.Mutex.create ();
      next_id = 0;
    }
  in
  let consumer =
    Bus.consumer bus ~uri:"in-memory://broker.bar-updated" ~group:"sse-stream"
      ~deserialize:(fun s -> Bar_updated_ie.t_of_yojson (Yojson.Safe.from_string s))
  in
  let _ : Bus.subscription = Bus.subscribe consumer (handle_bus_event t) in
  t

let connect t : subscriber =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let id = t.next_id in
      t.next_id <- t.next_id + 1;
      let s = { id; queue = Eio.Stream.create 64; bar_keys = KSet.empty } in
      t.subscribers <- s :: t.subscribers;
      s)

(** True iff some other subscriber holds [key]. Caller holds [t.mutex]. *)
let key_has_other_owner t (subscriber : subscriber) key =
  List.exists (fun s -> s.id <> subscriber.id && KSet.mem key s.bar_keys) t.subscribers

let subscribe_bar t (subscriber : subscriber) ~instrument ~timeframe : Candle.t list =
  let key = (instrument, timeframe) in
  let seed, first =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        if KSet.mem key subscriber.bar_keys then
          let existing =
            match KMap.find_opt key t.feeds with
            | Some f -> f.last_candles
            | None -> []
          in
          (existing, false)
        else begin
          subscriber.bar_keys <- KSet.add key subscriber.bar_keys;
          match KMap.find_opt key t.feeds with
          | Some f -> (f.last_candles, false)
          | None ->
              let f = { last_candles = []; stale_warned = false } in
              t.feeds <- KMap.add key f t.feeds;
              ([], true)
        end)
  in
  (if first then
     try t.on_first ~instrument ~timeframe
     with e -> Log.warn "stream on_first_subscriber failed: %s" (Printexc.to_string e));
  seed

(** Drop [key] from [subscriber]'s [bar_keys]; if no other subscriber
    holds it, remove the feed. Returns [true] iff the feed was the
    last and was removed. Caller holds [t.mutex] and must ensure
    [KSet.mem key subscriber.bar_keys]. *)
let drop_bar_key_locked t (subscriber : subscriber) key =
  subscriber.bar_keys <- KSet.remove key subscriber.bar_keys;
  if not (key_has_other_owner t subscriber key) then
    match KMap.find_opt key t.feeds with
    | Some _ ->
        t.feeds <- KMap.remove key t.feeds;
        true
    | None -> false
  else false

let unsubscribe_bar t (subscriber : subscriber) ~instrument ~timeframe =
  let key = (instrument, timeframe) in
  let was_last =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        if KSet.mem key subscriber.bar_keys then drop_bar_key_locked t subscriber key
        else false)
  in
  if was_last then
    try t.on_last ~instrument ~timeframe
    with e -> Log.warn "stream on_last_unsubscriber failed: %s" (Printexc.to_string e)

let disconnect t (subscriber : subscriber) =
  let lasts =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        let keys = KSet.elements subscriber.bar_keys in
        let lasts = List.filter (fun k -> drop_bar_key_locked t subscriber k) keys in
        t.subscribers <- List.filter (fun s -> s.id <> subscriber.id) t.subscribers;
        lasts)
  in
  List.iter
    (fun (instrument, timeframe) ->
      try t.on_last ~instrument ~timeframe
      with e -> Log.warn "stream on_last_unsubscriber failed: %s" (Printexc.to_string e))
    lasts

(** Broadcast publish for the [order] SSE channel.

    Wraps the caller-supplied JSON in [event: order\n data: ...\n\n]
    framing and pushes the chunk to every connected subscriber's
    queue, regardless of which bar feeds they declared interest in.
    The publisher (in [domain_event_handlers]) is responsible for
    shaping the JSON — typically [{"kind": "placed" | "rejected" | ..., ...}]
    — and for projecting domain events into integration-event DTOs
    before calling here.

    Order events share a single ordering domain on the subscriber
    side (see [docs/architecture/functional-hexagonal.md]); each
    subscriber processes them via a sequential queue under one
    [addEventListener("order", ...)]. *)
let publish_order t (data : Yojson.Safe.t) : unit =
  let chunk = "event: order\ndata: " ^ Yojson.Safe.to_string data ^ "\n\n" in
  let subscribers = Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.subscribers) in
  List.iter (fun s -> Eio.Stream.add s.queue chunk) subscribers
