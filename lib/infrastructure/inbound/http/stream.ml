(** Multi-channel SSE registry. One subscriber = one SSE connection,
    multiplexes any number of channels:

    - per-key bar feeds (each [(instrument, timeframe)] is independent);
    - global order broadcast.

    Pure state machine: no bus knowledge, no ACL knowledge, no
    transport awareness. Bars are injected through {!push_bar}
    by an outside caller (today: the trading-host factory's bus
    consumer for [broker.bar-updated]). The registry caches the
    latest candles per [(instrument, timeframe)] and fans
    framed SSE chunks out to subscribers that declared interest
    in the key. Late SSE joiners receive the cache as their
    seed; the chart UI is expected to pull deeper history
    through [/api/candles] before opening the stream.

    Whether the upstream [(instrument, timeframe)] is actually open
    is the broker BC's concern; this registry just forwards
    interest declarations through [on_first_subscriber] /
    [on_last_unsubscriber] so the caller can publish the matching
    {!Watch_bars_command} / {!Unwatch_bars_command}. The headless
    watchlist in the composition root takes the same
    [Broker.subscribe] path and coexists via the adapter-side
    refcount. *)

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

module SSet = Set.Make (String)
(** Footprint feeds are keyed by a plain string [symbol|boundary-token]
    rather than [(Instrument.t * Timeframe.t)]: the boundary token can be
    a timeframe ("M5") or a volume cap ("VOL:1000"), which a [Timeframe.t]
    cannot hold. The footprint channel needs no registry-side feed state
    (no cache, no seed — clients pull [/api/footprints] first), so a
    per-subscriber interest set, plus the per-key 0->1 / 1->0 transitions
    that drive [on_first_footprint] / [on_last_footprint], is all it
    carries. *)

type subscriber = {
  id : int;
  queue : string Eio.Stream.t;
  mutable bar_keys : KSet.t;
  mutable footprint_keys : SSet.t;
}

type feed = {
  mutable last_candles : Candle.t list;
      (** True while stale bars are being dropped — log once on
      transition to stale, stay silent until a fresh bar arrives. *)
  mutable stale_warned : bool;
}

type lifecycle_hook = instrument:Instrument.t -> timeframe:Timeframe.t -> unit

type footprint_lifecycle_hook = symbol:string -> boundary:string -> unit
(** Footprint feeds are keyed by [(symbol, boundary-token)] strings, not
    [(Instrument.t, Timeframe.t)] — the boundary may be a volume cap
    ([VOL:1000]) a [Timeframe.t] cannot hold — so their lifecycle hooks
    carry the raw strings. The caller forwards them into a
    {!Watch_footprints_command} whose fields are likewise strings. *)

type t = {
  on_first : lifecycle_hook;
  on_last : lifecycle_hook;
  on_first_footprint : footprint_lifecycle_hook;
  on_last_footprint : footprint_lifecycle_hook;
  mutable feeds : feed KMap.t;
  mutable subscribers : subscriber list;
  mutex : Eio.Mutex.t;
  mutable next_id : int;
}

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

(** Inject a fresh bar observation: update the cached candle for
    [(instrument, timeframe)] and fan the framed SSE chunk out
    to every subscriber that holds the key. No-op when no
    subscriber holds the key (the feed doesn't exist) — this
    happens for keys opened by the headless watchlist but unused
    by any SSE client.

    Monotonicity is enforced upstream at the broker ACL
    boundary, so by the time an event reaches us it is already
    monotonic within its key. We keep a defensive last-ts guard
    anyway: it silences the surprising case of a brand-new SSE
    feed seeing a bar with a [ts] strictly older than something
    it already cached locally (e.g. cache populated by an
    earlier SSE session that this feed inherited), which would
    still violate the chart library's ascending-time invariant
    on the wire. *)
let push_bar t ~instrument ~timeframe (candle : Candle.t) =
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

(** [on_first_subscriber] fires the first time any subscriber declares
    interest in a [(instrument, timeframe)] key — the natural moment
    for the caller to publish a {!Watch_bars_command} so the broker
    BC opens an upstream feed for it. [on_last_unsubscriber] fires
    when the last interested subscriber drops the key, symmetric
    for {!Unwatch_bars_command}. The composition-root watchlist
    issues the same commands for keys it cares about; they coexist
    via the broker adapter's per-key refcount.

    [on_first_footprint] / [on_last_footprint] are the footprint
    counterparts: they fire on the 0->1 / 1->0 transitions of interest
    in a [(symbol, boundary-token)] feed so the caller can publish the
    matching {!Watch_footprints_command} / {!Unwatch_footprints_command}
    to the order_flow BC, which starts / stops fanning the tape into that
    boundary. The operator's default boundary is always built regardless,
    so dropping the last footprint watcher never blinds headless consumers
    (e.g. the strategy BC). *)
let create
    ?(on_first_subscriber : lifecycle_hook = fun ~instrument:_ ~timeframe:_ -> ())
    ?(on_last_unsubscriber : lifecycle_hook = fun ~instrument:_ ~timeframe:_ -> ())
    ?(on_first_footprint : footprint_lifecycle_hook = fun ~symbol:_ ~boundary:_ -> ())
    ?(on_last_footprint : footprint_lifecycle_hook = fun ~symbol:_ ~boundary:_ -> ())
    () =
  {
    on_first = on_first_subscriber;
    on_last = on_last_unsubscriber;
    on_first_footprint;
    on_last_footprint;
    feeds = KMap.empty;
    subscribers = [];
    mutex = Eio.Mutex.create ();
    next_id = 0;
  }

let connect t : subscriber =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let id = t.next_id in
      t.next_id <- t.next_id + 1;
      let s =
        {
          id;
          queue = Eio.Stream.create 64;
          bar_keys = KSet.empty;
          footprint_keys = SSet.empty;
        }
      in
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

(** The single definition of how a footprint feed key is spelled, so the
    subscribe side (the [?footprints=] query parser) and the push side
    (the bus consumer decoding a footprint integration event) cannot
    drift apart. [symbol] is the qualified instrument; [token] is the
    boundary token ("M5", "VOL:1000"). *)
let footprint_key ~symbol ~token = symbol ^ "|" ^ token

(** Inverse of {!footprint_key}: split a stored key back into its
    [(symbol, token)] on the first ['|']. Total over keys produced by
    {!footprint_key} — a qualified symbol contains no ['|'] and a
    boundary token contains no ['|'], so the first separator is the only
    one. Used to recover the arguments for the lifecycle hook from a key
    held in a subscriber's set (e.g. at [disconnect]). *)
let split_footprint_key key =
  match String.index_opt key '|' with
  | None -> None
  | Some i -> Some (String.sub key 0 i, String.sub key (i + 1) (String.length key - i - 1))

(** Drop [key] from [subscriber]'s [footprint_keys]; return [true] iff no
    other subscriber still holds it (the 1->0 transition). Caller holds
    [t.mutex] and must ensure [SSet.mem key subscriber.footprint_keys]. *)
let drop_footprint_key_locked t (subscriber : subscriber) key =
  subscriber.footprint_keys <- SSet.remove key subscriber.footprint_keys;
  not
    (List.exists
       (fun s -> s.id <> subscriber.id && SSet.mem key s.footprint_keys)
       t.subscribers)

let disconnect t (subscriber : subscriber) =
  let bar_lasts, footprint_lasts =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        let bar_keys = KSet.elements subscriber.bar_keys in
        let bar_lasts =
          List.filter (fun k -> drop_bar_key_locked t subscriber k) bar_keys
        in
        let footprint_keys = SSet.elements subscriber.footprint_keys in
        let footprint_lasts =
          List.filter (fun k -> drop_footprint_key_locked t subscriber k) footprint_keys
        in
        t.subscribers <- List.filter (fun s -> s.id <> subscriber.id) t.subscribers;
        (bar_lasts, footprint_lasts))
  in
  List.iter
    (fun (instrument, timeframe) ->
      try t.on_last ~instrument ~timeframe
      with e -> Log.warn "stream on_last_unsubscriber failed: %s" (Printexc.to_string e))
    bar_lasts;
  List.iter
    (fun key ->
      match split_footprint_key key with
      | Some (symbol, boundary) -> (
          try t.on_last_footprint ~symbol ~boundary
          with e ->
            Log.warn "stream on_last_footprint failed: %s" (Printexc.to_string e))
      | None -> ())
    footprint_lasts

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

(** Declare interest in a footprint feed for [(symbol, token)] (the
    qualified symbol and the boundary token, e.g. ["M5"], ["VOL:1000"]).
    Unlike bars there is no seed — the chart pulls recent footprints
    through [/api/footprints] before opening the stream. On the 0->1
    transition (no subscriber held this feed before) [on_first_footprint]
    fires so the caller can publish a {!Watch_footprints_command}; the
    order_flow BC then starts fanning the tape into that boundary on top
    of the always-on default. *)
let subscribe_footprint t (subscriber : subscriber) ~symbol ~token : unit =
  let key = footprint_key ~symbol ~token in
  let first =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        if SSet.mem key subscriber.footprint_keys then false
        else begin
          let already_owned =
            List.exists (fun s -> SSet.mem key s.footprint_keys) t.subscribers
          in
          subscriber.footprint_keys <- SSet.add key subscriber.footprint_keys;
          not already_owned
        end)
  in
  if first then
    try t.on_first_footprint ~symbol ~boundary:token
    with e -> Log.warn "stream on_first_footprint failed: %s" (Printexc.to_string e)

(** Release [subscriber]'s interest in the [(symbol, token)] footprint
    feed; on the 1->0 transition (no other subscriber holds it)
    [on_last_footprint] fires so the caller can publish an
    {!Unwatch_footprints_command}. Symmetric to {!subscribe_footprint};
    [disconnect] releases any feeds still held. *)
let unsubscribe_footprint t (subscriber : subscriber) ~symbol ~token : unit =
  let key = footprint_key ~symbol ~token in
  let was_last =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        if SSet.mem key subscriber.footprint_keys then
          drop_footprint_key_locked t subscriber key
        else false)
  in
  if was_last then
    try t.on_last_footprint ~symbol ~boundary:token
    with e -> Log.warn "stream on_last_footprint failed: %s" (Printexc.to_string e)

(** Fan one sealed-footprint payload out to subscribers that declared
    interest in its [key]. [data] is the already-decoded footprint DTO;
    it rides the [footprint] SSE channel with [kind: "footprint"] and the
    [symbol] / [timeframe] fields the DTO already carries, so a
    multi-feed connection can route inside one
    [addEventListener("footprint", …)]. No-op when no subscriber holds
    the key. *)
let push_footprint t ~key (data : Yojson.Safe.t) : unit =
  let chunk =
    "event: footprint\ndata: "
    ^ Yojson.Safe.to_string (`Assoc [ ("kind", `String "footprint"); ("payload", data) ])
    ^ "\n\n"
  in
  let subs =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        List.filter (fun s -> SSet.mem key s.footprint_keys) t.subscribers)
  in
  List.iter (fun s -> Eio.Stream.add s.queue chunk) subs
