(** Exercises the real SSE registry's footprint channel
    ({!Server.Stream}): a sealed footprint pushed for a given
    [(symbol, boundary-token)] reaches exactly the subscribers that
    declared interest in that feed, framed on the [footprint] SSE
    channel. This is the load-bearing phase-3 logic — per-key fan-out
    and the subscribe/push key agreement — driven through the same
    [Eio.Stream] queue an SSE connection drains. *)

module Stream = Server.Stream

(* Non-blocking drain of everything currently queued for a subscriber. *)
let drain (s : Stream.subscriber) : string list =
  let rec go acc =
    match Eio.Stream.take_nonblocking s.Stream.queue with
    | Some chunk -> go (chunk :: acc)
    | None -> List.rev acc
  in
  go []

let contains ~needle s =
  let nl = String.length needle and sl = String.length s in
  let rec go i = i + nl <= sl && (String.sub s i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let fp_payload ~symbol ~token =
  (* A minimal footprint DTO — only the fields the routing/marshalling
     touches matter here. *)
  `Assoc
    [ ("symbol", `String symbol); ("timeframe", `String token); ("delta", `String "5") ]

let test_push_reaches_only_interested () =
  Eio_main.run @@ fun _env ->
  let reg = Stream.create () in
  let a = Stream.connect reg in
  let b = Stream.connect reg in
  (* a wants SBER M5; b wants GAZP M5 *)
  Stream.subscribe_footprint reg a ~symbol:"SBER@MISX" ~token:"M5";
  Stream.subscribe_footprint reg b ~symbol:"GAZP@MISX" ~token:"M5";
  Stream.push_footprint reg
    ~key:(Stream.footprint_key ~symbol:"SBER@MISX" ~token:"M5")
    (fp_payload ~symbol:"SBER@MISX" ~token:"M5");
  let a_chunks = drain a and b_chunks = drain b in
  Alcotest.(check int) "interested subscriber got 1 chunk" 1 (List.length a_chunks);
  Alcotest.(check int) "uninterested subscriber got nothing" 0 (List.length b_chunks);
  let chunk = List.hd a_chunks in
  Alcotest.(check bool)
    "framed on the footprint channel" true
    (contains ~needle:"event: footprint" chunk);
  Alcotest.(check bool)
    "carries kind:footprint" true
    (contains ~needle:"\"kind\":\"footprint\"" chunk);
  Alcotest.(check bool) "wraps the payload" true (contains ~needle:"\"payload\"" chunk);
  Alcotest.(check bool)
    "payload delta preserved" true
    (contains ~needle:"\"delta\":\"5\"" chunk)

(* The boundary token may itself contain a colon ("VOL:1000"); the key
   must keep instrument and token distinct so a volume feed is isolated
   from a same-instrument time feed. *)
let test_volume_token_key_isolation () =
  Eio_main.run @@ fun _env ->
  let reg = Stream.create () in
  let vol = Stream.connect reg in
  let m5 = Stream.connect reg in
  Stream.subscribe_footprint reg vol ~symbol:"SBER@MISX" ~token:"VOL:1000";
  Stream.subscribe_footprint reg m5 ~symbol:"SBER@MISX" ~token:"M5";
  Stream.push_footprint reg
    ~key:(Stream.footprint_key ~symbol:"SBER@MISX" ~token:"VOL:1000")
    (fp_payload ~symbol:"SBER@MISX" ~token:"VOL:1000");
  Alcotest.(check int) "volume feed received" 1 (List.length (drain vol));
  Alcotest.(check int) "time feed of same instrument did NOT" 0 (List.length (drain m5))

let test_no_subscriber_is_noop () =
  Eio_main.run @@ fun _env ->
  let reg = Stream.create () in
  let s = Stream.connect reg in
  (* s declares interest in a DIFFERENT key than the push *)
  Stream.subscribe_footprint reg s ~symbol:"SBER@MISX" ~token:"M1";
  Stream.push_footprint reg
    ~key:(Stream.footprint_key ~symbol:"SBER@MISX" ~token:"M5")
    (fp_payload ~symbol:"SBER@MISX" ~token:"M5");
  Alcotest.(check int)
    "no matching subscriber -> nothing queued" 0
    (List.length (drain s))

(* The host-side publisher seam: a real footprint integration event,
   decoded as it would be off the bus, must derive the feed key from its
   own instrument view model + boundary token and reach a subscriber
   that asked for exactly that (qualified-symbol, token) — including the
   /BOARD suffix. This is what the factory's footprint bus consumer runs
   per event. *)
let board_ie ~ticker ~venue ?board ~token () :
    Server.Publish_footprint_events.Footprint_completed.t =
  {
    instrument = { ticker; venue; isin = None; board };
    timeframe = token;
    open_ts = "2026-06-01T10:00:00Z";
    open_price = "100";
    high = "101";
    low = "99";
    close = "100";
    volume = "10";
    delta = "5";
    poc_price = "100";
    clusters = [];
  }

let test_publisher_derives_key_with_board () =
  Eio_main.run @@ fun _env ->
  let reg = Stream.create () in
  let s = Stream.connect reg in
  Stream.subscribe_footprint reg s ~symbol:"SBER@MISX/TQBR" ~token:"M5";
  Server.Publish_footprint_events.handle ~registry:reg
    (board_ie ~ticker:"SBER" ~venue:"MISX" ~board:"TQBR" ~token:"M5" ());
  let chunks = drain s in
  Alcotest.(check int) "board-qualified key routed to subscriber" 1 (List.length chunks);
  Alcotest.(check bool)
    "delta carried through publisher" true
    (contains ~needle:"\"delta\":\"5\"" (List.hd chunks))

(* Demand wiring: the first watcher of a footprint feed must fire
   [on_first_footprint] (the host turns that into a Watch_footprints_command);
   a second watcher of the SAME feed must not re-fire it; and the feed's
   [on_last_footprint] must fire only when the LAST watcher drops it
   (including via disconnect). This refcount is what lets the order_flow
   default boundary stay untouched while extra UI-requested boundaries
   come and go. *)
let test_lifecycle_hooks_refcount_per_feed () =
  Eio_main.run @@ fun _env ->
  let watched = ref [] and unwatched = ref [] in
  let reg =
    Stream.create
      ~on_first_footprint:(fun ~symbol ~boundary ->
        watched := (symbol, boundary) :: !watched)
      ~on_last_footprint:(fun ~symbol ~boundary ->
        unwatched := (symbol, boundary) :: !unwatched)
      ()
  in
  let a = Stream.connect reg in
  let b = Stream.connect reg in
  Stream.subscribe_footprint reg a ~symbol:"SBER@MISX" ~token:"M1";
  Stream.subscribe_footprint reg b ~symbol:"SBER@MISX" ~token:"M1";
  Alcotest.(check (list (pair string string)))
    "on_first fired exactly once for the feed"
    [ ("SBER@MISX", "M1") ]
    !watched;
  Stream.unsubscribe_footprint reg a ~symbol:"SBER@MISX" ~token:"M1";
  Alcotest.(check int)
    "no on_last while another watcher holds it" 0 (List.length !unwatched);
  Stream.disconnect reg b;
  Alcotest.(check (list (pair string string)))
    "on_last fired once when the last watcher dropped"
    [ ("SBER@MISX", "M1") ]
    !unwatched

let tests =
  [
    ("push reaches only interested subscribers", `Quick, test_push_reaches_only_interested);
    ("volume token key isolates from time feed", `Quick, test_volume_token_key_isolation);
    ("push with no matching subscriber is a no-op", `Quick, test_no_subscriber_is_noop);
    ( "publisher derives feed key (with board)",
      `Quick,
      test_publisher_derives_key_with_board );
    ( "footprint lifecycle hooks refcount per feed",
      `Quick,
      test_lifecycle_hooks_refcount_per_feed );
  ]
