(** Per-(instrument, timeframe) live candle subscription registry.
    Stage 1 of real-time support: server polls the data source at a
    cadence keyed to the timeframe, compares the tail of the candle
    stream against a cache, and fans out update events to all SSE
    subscribers of the same key. One upstream poll per key — opening
    N UI tabs on the same chart never multiplies the load on Finam. *)

open Core

type event =
  | Bar_update of Candle.t   (* same ts as last cached bar, OHLCV changed *)
  | Bar_closed of Candle.t   (* a new bar appeared after the last cached *)

let encode_event : event -> string = function
  | Bar_update c ->
    let j : Yojson.Safe.t = `Assoc [
      "kind",   `String "bar_update";
      "candle", Candle_json.yojson_of_t c;
    ] in
    "data: " ^ Yojson.Safe.to_string j ^ "\n\n"
  | Bar_closed c ->
    let j : Yojson.Safe.t = `Assoc [
      "kind",   `String "bar_closed";
      "candle", Candle_json.yojson_of_t c;
    ] in
    "data: " ^ Yojson.Safe.to_string j ^ "\n\n"

type client = {
  id : int;
  queue : string Eio.Stream.t;
}

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
}

type fetch =
  instrument:Instrument.t -> n:int -> timeframe:Timeframe.t -> Candle.t list

type t = {
  env : Eio_unix.Stdenv.base;
  fetch : fetch;
  mutable subs : sub_state KMap.t;
  mutex : Eio.Mutex.t;
  mutable next_id : int;
  sw : Eio.Switch.t;
}

let create ~env ~sw ~fetch = {
  env; sw; fetch;
  subs = KMap.empty;
  mutex = Eio.Mutex.create ();
  next_id = 0;
}

(** Intra-bar mutation detector: two bars with the same [ts] are
    considered distinct if their OHLC or volume diverge. *)
let same_bar (a : Candle.t) (b : Candle.t) =
  Int64.equal a.ts b.ts &&
  Decimal.equal a.open_ b.open_ &&
  Decimal.equal a.high b.high &&
  Decimal.equal a.low b.low &&
  Decimal.equal a.close b.close &&
  Decimal.equal a.volume b.volume

let last = function [] -> None | l -> Some (List.nth l (List.length l - 1))

(** Compute the ordered events to emit given a fresh snapshot and the
    previously-cached candle list. Emits [Bar_closed] for every bar
    strictly newer than the last cached one (chronologically) and
    [Bar_update] when the trailing bar kept its timestamp but drifted. *)
let diff_and_emit ~cached ~fresh : event list =
  match last fresh, last cached with
  | None, _ -> []
  | Some fl, None -> [Bar_closed fl]
  | Some fl, Some cl ->
    let cmp = Int64.compare fl.Candle.ts cl.Candle.ts in
    if cmp > 0 then
      fresh
      |> List.filter (fun c -> Int64.compare c.Candle.ts cl.Candle.ts > 0)
      |> List.map (fun c -> Bar_closed c)
    else if cmp = 0 && not (same_bar fl cl) then [Bar_update fl]
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
       Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
         sub.last_candles <- initial)
     with e ->
       Log.warn "stream seed %s/%s failed: %s"
         (Instrument.to_qualified instrument)
         (Timeframe.to_string timeframe)
         (Printexc.to_string e));
    while !running do
      Eio.Time.sleep clock interval;
      if !running then
        (try
           let fresh = t.fetch ~instrument ~n:500 ~timeframe in
           let events, clients =
             Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
               let evs = diff_and_emit ~cached:sub.last_candles ~fresh in
               sub.last_candles <- fresh;
               evs, sub.clients)
           in
           List.iter (fun ev ->
             let chunk = encode_event ev in
             List.iter (fun c -> Eio.Stream.add c.queue chunk) clients
           ) events
         with e ->
           Log.warn "stream poll %s/%s failed: %s"
             (Instrument.to_qualified instrument)
             (Timeframe.to_string timeframe)
             (Printexc.to_string e))
    done;
    `Stop_daemon)

let subscribe t ~instrument ~timeframe : client * Candle.t list =
  let key = (instrument, timeframe) in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    let id = t.next_id in
    t.next_id <- t.next_id + 1;
    let client = { id; queue = Eio.Stream.create 64 } in
    match KMap.find_opt key t.subs with
    | Some s ->
      s.clients <- client :: s.clients;
      client, s.last_candles
    | None ->
      let s = {
        clients = [client];
        last_candles = [];
        cancel = (fun () -> ());
      } in
      t.subs <- KMap.add key s t.subs;
      start_poll t key s;
      client, [])

let unsubscribe t ~instrument ~timeframe (client : client) =
  let key = (instrument, timeframe) in
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
    match KMap.find_opt key t.subs with
    | None -> ()
    | Some s ->
      s.clients <- List.filter (fun c -> c.id <> client.id) s.clients;
      if s.clients = [] then begin
        s.cancel ();
        t.subs <- KMap.remove key t.subs
      end)

(** Injection point for alternative upstream sources (WebSocket bridge).
    Updates the cached candle for [(instrument, timeframe)] so the
    polling fiber doesn't re-emit a duplicate, then fans the event out
    to all registered SSE clients of that key. No-op if the key has
    no subscribers yet. *)
let push_from_upstream t ~instrument ~timeframe (candle : Candle.t) =
  let key = (instrument, timeframe) in
  let chunk_opt =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match KMap.find_opt key t.subs with
      | None -> None
      | Some s ->
        let event =
          match last s.last_candles with
          | Some cl when Int64.equal cl.Candle.ts candle.ts ->
            Bar_update candle
          | _ -> Bar_closed candle
        in
        (* Update cache: either replace trailing bar or append. *)
        let cached =
          match last s.last_candles with
          | Some cl when Int64.equal cl.Candle.ts candle.ts ->
            (match List.rev s.last_candles with
             | _ :: rest -> List.rev (candle :: rest)
             | [] -> [candle])
          | _ -> s.last_candles @ [candle]
        in
        s.last_candles <- cached;
        Some (encode_event event, s.clients))
  in
  match chunk_opt with
  | None -> ()
  | Some (chunk, clients) ->
    List.iter (fun c -> Eio.Stream.add c.queue chunk) clients
