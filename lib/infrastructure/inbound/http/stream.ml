(** Per-(instrument, timeframe) live candle subscription registry.
    Stage 1 of real-time support: server polls the data source at a
    cadence keyed to the timeframe, compares the tail of the candle
    stream against a cache, and fans out update events to all SSE
    subscribers of the same key. One upstream poll per key — opening
    N UI tabs on the same chart never multiplies the load on Finam. *)

open Core

type event =
  | Bar_updated of Candle.t (* same ts as last cached bar, OHLCV changed *)
  | Bar_closed of Candle.t (* a new bar appeared after the last cached *)

(** Encode to SSE wire format with explicit [event:] field — the
    SSE protocol's native channel mechanism. On the browser side
    [es.addEventListener("bar", ...)] catches only these messages
    and inside the handler the [kind] field discriminates
    [updated] (intra-bar mutation) from [closed] (new bar).

    Both variants share an ordering domain (same instrument,
    same timeframe), so they ride one channel and a single
    sequential consumer on the client preserves their order. *)
let encode_event : event -> string = function
  | Bar_updated c ->
      let j : Yojson.Safe.t =
        `Assoc [ ("kind", `String "updated"); ("candle", Api.candle_json c) ]
      in
      "event: bar\ndata: " ^ Yojson.Safe.to_string j ^ "\n\n"
  | Bar_closed c ->
      let j : Yojson.Safe.t =
        `Assoc [ ("kind", `String "closed"); ("candle", Api.candle_json c) ]
      in
      "event: bar\ndata: " ^ Yojson.Safe.to_string j ^ "\n\n"

type client = { id : int; queue : string Eio.Stream.t }

type key = Instrument.t * Timeframe.t

module Key = struct
  type t = key
  let compare (i1, t1) (i2, t2) =
    let c = Instrument.compare i1 i2 in
    if c <> 0 then c else compare t1 t2
end

module KMap = Map.Make (Key)

type sub_state = {
  mutable clients : client list;
  mutable last_candles : Candle.t list;
  mutable cancel : unit -> unit;
      (** True while stale bars are being dropped — log once on
      transition to stale, stay silent until a fresh bar arrives. *)
  mutable stale_warned : bool;
      (** Wall-clock time of the last upstream (WS) push. When WS is
      actively streaming the polling fiber skips its tick, avoiding
      duplicate REST round-trips for data the WS already delivered. *)
  mutable last_upstream_push : float option;
}

type fetch = instrument:Instrument.t -> n:int -> timeframe:Timeframe.t -> Candle.t list

type lifecycle_hook = instrument:Instrument.t -> timeframe:Timeframe.t -> unit

type t = {
  env : Eio_unix.Stdenv.base;
  fetch : fetch;
  on_first : lifecycle_hook;
  on_last : lifecycle_hook;
  mutable subs : sub_state KMap.t;
  mutex : Eio.Mutex.t;
  mutable next_id : int;
  sw : Eio.Switch.t;
}

(** [on_first_subscriber] fires when the first SSE client subscribes
    to a [(instrument, timeframe)] key — the natural moment to forward
    the subscription to an upstream WS. [on_last_unsubscriber] fires
    when the last client of a key disconnects, so the upstream
    subscription can be released. Both default to no-ops, keeping
    [Stream] free of any broker knowledge. *)
let create
    ?(on_first_subscriber : lifecycle_hook = fun ~instrument:_ ~timeframe:_ -> ())
    ?(on_last_unsubscriber : lifecycle_hook = fun ~instrument:_ ~timeframe:_ -> ())
    ~env
    ~sw
    ~fetch
    () =
  {
    env;
    sw;
    fetch;
    on_first = on_first_subscriber;
    on_last = on_last_unsubscriber;
    subs = KMap.empty;
    mutex = Eio.Mutex.create ();
    next_id = 0;
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

(** Compute the ordered events to emit given a fresh snapshot and the
    previously-cached candle list. Emits [Bar_closed] for every bar
    strictly newer than the last cached one (chronologically) and
    [Bar_updated] when the trailing bar kept its timestamp but drifted. *)
let diff_and_emit ~cached ~fresh : event list =
  match (last fresh, last cached) with
  | None, _ -> []
  | Some fl, None -> [ Bar_closed fl ]
  | Some fl, Some cl ->
      let cmp = Int64.compare fl.Candle.ts cl.Candle.ts in
      if cmp > 0 then
        fresh
        |> List.filter (fun c -> Int64.compare c.Candle.ts cl.Candle.ts > 0)
        |> List.map (fun c -> Bar_closed c)
      else if cmp = 0 && not (same_bar fl cl) then [ Bar_updated fl ]
      else []

let poll_interval_seconds (tf : Timeframe.t) : float =
  let s = float_of_int (Timeframe.to_seconds tf) in
  Float.max 2.0 (Float.min 30.0 (s /. 12.0))

let start_poll t (key : key) (sub : sub_state) =
  let instrument, timeframe = key in
  let interval = poll_interval_seconds timeframe in
  let running = ref true in
  sub.cancel <- (fun () -> running := false);
  let clock = Eio.Stdenv.clock t.env in
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      (try
         let initial = t.fetch ~instrument ~n:500 ~timeframe in
         Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> sub.last_candles <- initial)
       with e ->
         Log.warn "stream seed %s/%s failed: %s"
           (Instrument.to_qualified instrument)
           (Timeframe.to_string timeframe)
           (Printexc.to_string e));
      while !running do
        Eio.Time.sleep clock interval;
        let ws_fresh =
          match sub.last_upstream_push with
          | None -> false
          | Some ts ->
              (* Skip this poll tick when WS delivered something recently.
             Threshold: 2× the poll interval. If WS goes quiet for
             that long (disconnect, session boundary, broker stall),
             polling resumes automatically. *)
              Eio.Time.now clock -. ts < 2.0 *. interval
        in
        if !running && not ws_fresh then
          try
            let fresh = t.fetch ~instrument ~n:500 ~timeframe in
            let events, clients =
              Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
                  (* Merge fresh (REST snapshot) with any live WS updates
                  that landed after the last poll. REST can lag WS by
                  a minute or more (Finam caches at minute boundaries),
                  so unconditionally replacing the cache would roll its
                  tail backwards — the next WS candle would then look
                  "newer" than the cache tail and get re-emitted as
                  Bar_closed, producing spurious duplicate-ts events.

                  Strategy: keep every cached bar strictly newer than
                  fresh's tail, append it after the REST history. *)
                  let merged =
                    match (last fresh, last sub.last_candles) with
                    | None, _ -> sub.last_candles (* poll empty → keep cache *)
                    | Some _, None -> fresh
                    | Some fl, Some _ ->
                        let ws_tail =
                          List.filter
                            (fun (c : Candle.t) -> Int64.compare c.ts fl.ts > 0)
                            sub.last_candles
                        in
                        fresh @ ws_tail
                  in
                  let evs = diff_and_emit ~cached:sub.last_candles ~fresh:merged in
                  sub.last_candles <- merged;
                  (evs, sub.clients))
            in
            List.iter
              (fun ev ->
                let chunk = encode_event ev in
                List.iter (fun c -> Eio.Stream.add c.queue chunk) clients)
              events
          with e ->
            Log.warn "stream poll %s/%s failed: %s"
              (Instrument.to_qualified instrument)
              (Timeframe.to_string timeframe)
              (Printexc.to_string e)
      done;
      `Stop_daemon)

let subscribe t ~instrument ~timeframe : client * Candle.t list =
  let key = (instrument, timeframe) in
  let client, seed, first =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        let id = t.next_id in
        t.next_id <- t.next_id + 1;
        let client = { id; queue = Eio.Stream.create 64 } in
        match KMap.find_opt key t.subs with
        | Some s ->
            s.clients <- client :: s.clients;
            (client, s.last_candles, false)
        | None ->
            let s =
              {
                clients = [ client ];
                last_candles = [];
                cancel = (fun () -> ());
                stale_warned = false;
                last_upstream_push = None;
              }
            in
            t.subs <- KMap.add key s t.subs;
            start_poll t key s;
            (client, [], true))
  in
  (if first then
     try t.on_first ~instrument ~timeframe
     with e -> Log.warn "stream on_first_subscriber failed: %s" (Printexc.to_string e));
  (client, seed)

let unsubscribe t ~instrument ~timeframe (client : client) =
  let key = (instrument, timeframe) in
  let last =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        match KMap.find_opt key t.subs with
        | None -> false
        | Some s ->
            s.clients <- List.filter (fun c -> c.id <> client.id) s.clients;
            if s.clients = [] then begin
              s.cancel ();
              t.subs <- KMap.remove key t.subs;
              true
            end
            else false)
  in
  if last then
    try t.on_last ~instrument ~timeframe
    with e -> Log.warn "stream on_last_unsubscriber failed: %s" (Printexc.to_string e)

(** Injection point for alternative upstream sources (WebSocket bridge).
    Updates the cached candle for [(instrument, timeframe)] so the
    polling fiber doesn't re-emit a duplicate, then fans the event out
    to all registered SSE clients of that key. No-op if the key has
    no subscribers yet. *)
let push_from_upstream t ~instrument ~timeframe (candle : Candle.t) =
  let key = (instrument, timeframe) in
  let now = Eio.Time.now (Eio.Stdenv.clock t.env) in
  let chunk_opt =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        match KMap.find_opt key t.subs with
        | None -> None
        | Some s -> (
            s.last_upstream_push <- Some now;
            (* Monotonicity guard. Upstream brokers occasionally ship a
           stale snapshot right after subscribe (BCS sends the last
           closed candle from the previous session when there's no
           current activity); the chart library [lightweight-charts]
           hard-asserts ascending time order, so out-of-order bars
           break the UI. Drop anything strictly older than the tail
           we already have. Same-ts bars are kept as intra-bar
           updates. *)
            match last s.last_candles with
            | None ->
                (* Cache not seeded yet — the polling fiber's initial fetch
             is still in flight. We can't compare against a tail we
             don't have, and brokers (notably BCS) often push a
             snapshot the instant a subscription is acked; that
             snapshot can legitimately be much older than what
             [/api/candles] already delivered to the client. Drop
             the WS event and wait for polling to seed the cache
             before forwarding anything. *)
                None
            | Some cl when Int64.compare candle.Candle.ts cl.Candle.ts < 0 ->
                if not s.stale_warned then begin
                  s.stale_warned <- true;
                  Log.warn
                    "stream: dropping stale upstream bars for %s/%s (upstream ts=%Ld < \
                     cached tail=%Ld)"
                    (Instrument.to_qualified instrument)
                    (Timeframe.to_string timeframe)
                    candle.ts cl.Candle.ts
                end;
                None
            | last_opt ->
                s.stale_warned <- false;
                let event =
                  match last_opt with
                  | Some cl when Int64.equal cl.Candle.ts candle.ts -> Bar_updated candle
                  | _ -> Bar_closed candle
                in
                let cached =
                  match last_opt with
                  | Some cl when Int64.equal cl.Candle.ts candle.ts -> (
                      match List.rev s.last_candles with
                      | _ :: rest -> List.rev (candle :: rest)
                      | [] -> [ candle ])
                  | _ -> s.last_candles @ [ candle ]
                in
                s.last_candles <- cached;
                Some (encode_event event, s.clients)))
  in
  match chunk_opt with
  | None -> ()
  | Some (chunk, clients) -> List.iter (fun c -> Eio.Stream.add c.queue chunk) clients
