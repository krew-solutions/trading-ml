(** Tests the Eio-to-Seq boundary adapter. Each test runs inside
    [Eio_main.run] so Eio.Stream is actually awakable. *)

let test_order_preserved () =
  Eio_main.run @@ fun _env ->
  let s = Eio.Stream.create 16 in
  List.iter (Eio.Stream.add s) [ 1; 2; 3; 4; 5 ];
  let seq = Eio_stream.of_eio_stream s in
  let first_five = seq |> Stream.take 5 |> Stream.to_list in
  Alcotest.(check (list int)) "order preserved" [ 1; 2; 3; 4; 5 ] first_five

let test_take_bounds_infinite_stream () =
  Eio_main.run @@ fun _env ->
  let s = Eio.Stream.create 64 in
  List.iter (Eio.Stream.add s) [ 10; 20; 30; 40; 50 ];
  let seq = Eio_stream.of_eio_stream s in
  (* take 3 из бесконечного Seq — не зависает, возвращает первые три. *)
  let three = seq |> Stream.take 3 |> Stream.to_list in
  Alcotest.(check (list int)) "take 3" [ 10; 20; 30 ] three

let test_consumer_blocks_until_producer_pushes () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let s = Eio.Stream.create 1 in
  let seq = Eio_stream.of_eio_stream s in
  let result = ref [] in
  (* Consumer fiber — tries to pull 3 values. Will block until they
     arrive. *)
  let consumer =
    Eio.Fiber.fork_promise ~sw (fun () ->
        result := seq |> Stream.take 3 |> Stream.to_list;
        !result)
  in
  (* Producer pushes after a small yield — proves consumer actually
     suspends, not busy-waits. *)
  Eio.Fiber.yield ();
  Eio.Stream.add s 100;
  Eio.Fiber.yield ();
  Eio.Stream.add s 200;
  Eio.Fiber.yield ();
  Eio.Stream.add s 300;
  let got = Eio.Promise.await_exn consumer in
  Alcotest.(check (list int)) "consumer woke for each push" [ 100; 200; 300 ] got

let test_lazy_scan_map_over_live_source () =
  Eio_main.run @@ fun _env ->
  let s = Eio.Stream.create 16 in
  List.iter (Eio.Stream.add s) [ 1; 2; 3; 4; 5 ];
  let cumsum =
    Eio_stream.of_eio_stream s
    |> Stream.scan_map 0 (fun acc x -> (acc + x, acc + x))
    |> Stream.take 5 |> Stream.to_list
  in
  Alcotest.(check (list int)) "cumsum over live-ish source" [ 1; 3; 6; 10; 15 ] cumsum

let tests =
  [
    ("order preserved", `Quick, test_order_preserved);
    ("take bounds infinite stream", `Quick, test_take_bounds_infinite_stream);
    ("consumer blocks until push", `Quick, test_consumer_blocks_until_producer_pushes);
    ("pipeline over live source", `Quick, test_lazy_scan_map_over_live_source);
  ]
