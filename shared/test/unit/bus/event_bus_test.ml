(** Tests for {!Event_bus}.

    Same synchronisation pattern as {!Command_bus_test}: positive
    delivery observed via [Eio.Stream.take] from the subscriber;
    "no delivery" / ordering observed via mutable list + [yield_n]. *)

let yield_n n =
  for _ = 1 to n do
    Eio.Fiber.yield ()
  done

let with_bus f =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let bus =
    Bus.Event_bus.create ~sw ~to_string:string_of_int ~of_string:int_of_string ()
  in
  f bus

let test_subscribe_then_publish_delivers () =
  with_bus @@ fun bus ->
  let received = Eio.Stream.create 1 in
  let _ = Bus.Event_bus.subscribe bus (fun ev -> Eio.Stream.add received ev) in
  Bus.Event_bus.publish bus 7;
  Alcotest.(check int) "delivered" 7 (Eio.Stream.take received)

let test_publish_round_trips_through_codec () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let bus =
    Bus.Event_bus.create ~sw ~to_string:string_of_int
      ~of_string:(fun s -> int_of_string s * 10)
      ()
  in
  let received = Eio.Stream.create 1 in
  let _ = Bus.Event_bus.subscribe bus (fun ev -> Eio.Stream.add received ev) in
  Bus.Event_bus.publish bus 3;
  Alcotest.(check int) "decoded value seen" 30 (Eio.Stream.take received)

let test_multiple_subscribers_all_receive () =
  with_bus @@ fun bus ->
  let order = ref [] in
  let _ = Bus.Event_bus.subscribe bus (fun ev -> order := (1, ev) :: !order) in
  let _ = Bus.Event_bus.subscribe bus (fun ev -> order := (2, ev) :: !order) in
  Bus.Event_bus.publish bus 99;
  yield_n 5;
  (* Subscribers run in registration order; both prepend, so we read
     newest-first: [(2, 99); (1, 99)]. *)
  Alcotest.(check (list (pair int int)))
    "both received in registration order"
    [ (2, 99); (1, 99) ]
    !order

let test_unsubscribe_stops_delivery () =
  with_bus @@ fun bus ->
  let received = ref [] in
  let sub = Bus.Event_bus.subscribe bus (fun ev -> received := ev :: !received) in
  Bus.Event_bus.publish bus 1;
  yield_n 5;
  Bus.Event_bus.unsubscribe bus sub;
  Bus.Event_bus.publish bus 2;
  yield_n 5;
  Alcotest.(check (list int)) "only first event seen" [ 1 ] !received

let test_subscriber_exception_doesnt_break_others () =
  with_bus @@ fun bus ->
  let received = Eio.Stream.create 1 in
  let _ = Bus.Event_bus.subscribe bus (fun _ -> failwith "boom") in
  let _ = Bus.Event_bus.subscribe bus (fun ev -> Eio.Stream.add received ev) in
  Bus.Event_bus.publish bus 5;
  Alcotest.(check int) "second subscriber still got it" 5 (Eio.Stream.take received)

let test_deserialisation_failure_drops_event () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let bus =
    Bus.Event_bus.create ~sw ~to_string:Fun.id
      ~of_string:(fun s -> if s = "BAD" then failwith "bad payload" else s)
      ()
  in
  let received = Eio.Stream.create 1 in
  let _ = Bus.Event_bus.subscribe bus (fun ev -> Eio.Stream.add received ev) in
  Bus.Event_bus.publish bus "BAD";
  Bus.Event_bus.publish bus "ok";
  Alcotest.(check string) "good payload after bad" "ok" (Eio.Stream.take received)

let test_unsubscribe_unknown_id_is_noop () =
  with_bus @@ fun bus ->
  let sub = Bus.Event_bus.subscribe bus (fun _ -> ()) in
  Bus.Event_bus.unsubscribe bus sub;
  (* Second unsubscribe of the same handle must not raise. *)
  Bus.Event_bus.unsubscribe bus sub;
  let received = Eio.Stream.create 1 in
  let _ = Bus.Event_bus.subscribe bus (fun ev -> Eio.Stream.add received ev) in
  Bus.Event_bus.publish bus 1;
  Alcotest.(check int) "bus still alive" 1 (Eio.Stream.take received)

let test_event_order_preserved () =
  with_bus @@ fun bus ->
  let received = ref [] in
  let _ = Bus.Event_bus.subscribe bus (fun ev -> received := ev :: !received) in
  Bus.Event_bus.publish bus 1;
  Bus.Event_bus.publish bus 2;
  Bus.Event_bus.publish bus 3;
  yield_n 10;
  Alcotest.(check (list int)) "FIFO order" [ 3; 2; 1 ] !received

let tests =
  [
    ("subscribe then publish delivers", `Quick, test_subscribe_then_publish_delivers);
    ("publish round-trips through codec", `Quick, test_publish_round_trips_through_codec);
    ("multiple subscribers all receive", `Quick, test_multiple_subscribers_all_receive);
    ("unsubscribe stops delivery", `Quick, test_unsubscribe_stops_delivery);
    ( "subscriber exception doesn't break others",
      `Quick,
      test_subscriber_exception_doesnt_break_others );
    ( "deserialisation failure drops event",
      `Quick,
      test_deserialisation_failure_drops_event );
    ("unsubscribe unknown id is no-op", `Quick, test_unsubscribe_unknown_id_is_noop);
    ("event order preserved", `Quick, test_event_order_preserved);
  ]
