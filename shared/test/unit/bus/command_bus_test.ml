(** Tests for {!Command_bus}.

    The bus dispatches in a daemon fiber spawned on the test's
    [Switch], so positive tests synchronise on an [Eio.Stream] that
    the handler writes to (blocking [take] is the test's "wait for
    delivery"). Negative tests use a [ref] plus a few [yield]s, since
    "handler was NOT called" cannot be observed by a blocking read. *)

let int_codec = (string_of_int, int_of_string)

let yield_n n =
  for _ = 1 to n do
    Eio.Fiber.yield ()
  done

let with_bus f =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let to_string, of_string = int_codec in
  let bus = Bus.Command_bus.create ~sw ~to_string ~of_string () in
  f bus

let test_register_then_send_delivers () =
  with_bus @@ fun bus ->
  let received = Eio.Stream.create 1 in
  Bus.Command_bus.register_handler bus (fun cmd -> Eio.Stream.add received cmd);
  Bus.Command_bus.send bus 42;
  Alcotest.(check int) "delivered" 42 (Eio.Stream.take received)

let test_send_serialises_through_codec () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  (* of_string adds 1000 — proves the payload round-trips through
     to_string/of_string rather than being passed by reference. *)
  let bus =
    Bus.Command_bus.create ~sw ~to_string:string_of_int
      ~of_string:(fun s -> int_of_string s + 1000)
      ()
  in
  let received = Eio.Stream.create 1 in
  Bus.Command_bus.register_handler bus (fun cmd -> Eio.Stream.add received cmd);
  Bus.Command_bus.send bus 7;
  Alcotest.(check int) "decoded value seen" 1007 (Eio.Stream.take received)

let test_double_register_raises () =
  with_bus @@ fun bus ->
  Bus.Command_bus.register_handler bus (fun _ -> ());
  Alcotest.check_raises "second register raises" Bus.Command_bus.Already_registered
    (fun () -> Bus.Command_bus.register_handler bus (fun _ -> ()))

let test_send_without_handler_drops_silently () =
  with_bus @@ fun bus ->
  (* No handler registered — must not crash, must not block the
     daemon. Subsequent registrations & sends still work. *)
  Bus.Command_bus.send bus 1;
  yield_n 5;
  let received = Eio.Stream.create 1 in
  Bus.Command_bus.register_handler bus (fun cmd -> Eio.Stream.add received cmd);
  Bus.Command_bus.send bus 2;
  Alcotest.(check int) "later send delivered" 2 (Eio.Stream.take received)

let test_handler_exception_doesnt_kill_bus () =
  with_bus @@ fun bus ->
  let received = Eio.Stream.create 2 in
  Bus.Command_bus.register_handler bus (fun cmd ->
      if cmd = 1 then failwith "boom" else Eio.Stream.add received cmd);
  Bus.Command_bus.send bus 1;
  (* The first command's handler raised — bus must keep dispatching. *)
  Bus.Command_bus.send bus 2;
  Bus.Command_bus.send bus 3;
  Alcotest.(check int) "second delivered" 2 (Eio.Stream.take received);
  Alcotest.(check int) "third delivered" 3 (Eio.Stream.take received)

let test_deserialisation_failure_doesnt_kill_bus () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let bus =
    Bus.Command_bus.create ~sw ~to_string:Fun.id
      ~of_string:(fun s -> if s = "BAD" then failwith "bad payload" else s)
      ()
  in
  let received = Eio.Stream.create 1 in
  Bus.Command_bus.register_handler bus (fun cmd -> Eio.Stream.add received cmd);
  Bus.Command_bus.send bus "BAD";
  Bus.Command_bus.send bus "ok";
  Alcotest.(check string) "good payload after bad" "ok" (Eio.Stream.take received)

let tests =
  [
    ("register then send delivers", `Quick, test_register_then_send_delivers);
    ("send round-trips through codec", `Quick, test_send_serialises_through_codec);
    ("double register raises", `Quick, test_double_register_raises);
    ( "send without handler drops silently",
      `Quick,
      test_send_without_handler_drops_silently );
    ("handler exception doesn't kill bus", `Quick, test_handler_exception_doesnt_kill_bus);
    ( "deserialisation failure doesn't kill bus",
      `Quick,
      test_deserialisation_failure_doesnt_kill_bus );
  ]
