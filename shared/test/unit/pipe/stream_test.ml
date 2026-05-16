let test_of_list_to_list_roundtrip () =
  Alcotest.(check (list int))
    "roundtrip" [ 1; 2; 3 ]
    (Pipe.Stream.to_list (Pipe.Stream.of_list [ 1; 2; 3 ]))

let test_map () =
  Alcotest.(check (list int))
    "x2" [ 2; 4; 6 ]
    (Pipe.Stream.of_list [ 1; 2; 3 ] |> Pipe.Stream.map (fun x -> x * 2) |> Pipe.Stream.to_list)

let test_filter_map () =
  Alcotest.(check (list int))
    "evens * 10" [ 20; 40 ]
    (Pipe.Stream.of_list [ 1; 2; 3; 4 ]
    |> Pipe.Stream.filter_map (fun x -> if x mod 2 = 0 then Some (x * 10) else None)
    |> Pipe.Stream.to_list)

let test_scan_map_cumulative_sum () =
  (* Classic use: thread accumulator, emit running total. *)
  let cumsum =
    Pipe.Stream.of_list [ 1; 2; 3; 4; 5 ]
    |> Pipe.Stream.scan_map 0 (fun acc x ->
        let acc' = acc + x in
        (acc', acc'))
    |> Pipe.Stream.to_list
  in
  Alcotest.(check (list int)) "cumulative sums" [ 1; 3; 6; 10; 15 ] cumsum

let test_scan_map_lazy () =
  (* Prove laziness: scan_map applied to an infinite Seq must not loop. *)
  let nats = Pipe.Stream.unfold (fun n -> Some (n, n + 1)) 0 in
  let first_five =
    nats
    |> Pipe.Stream.scan_map 0 (fun acc x -> (acc + x, acc + x))
    |> Pipe.Stream.take 5 |> Pipe.Stream.to_list
  in
  Alcotest.(check (list int)) "cumsum of 0..4" [ 0; 1; 3; 6; 10 ] first_five

let test_scan_filter_map_gated () =
  (* Advance state always, emit only when predicate holds — classic
     "signal → order" gate. *)
  let emitted =
    Pipe.Stream.of_list [ 1; 2; 3; 4; 5; 6 ]
    |> Pipe.Stream.scan_filter_map 0 (fun acc x ->
        let acc' = acc + x in
        let out = if x mod 3 = 0 then Some acc' else None in
        (acc', out))
    |> Pipe.Stream.to_list
  in
  Alcotest.(check (list int))
    "only on multiples of 3" [ 6; 21 ]
    emitted (* acc after x=3 is 6, after x=6 is 1+2+3+4+5+6=21 *)

let test_scan_filter_map_state_advances_even_when_not_emitting () =
  (* Regression-shaped test: if the implementation accidentally skips
     the state update on [None], cumulative sum will be wrong. *)
  let emitted =
    Pipe.Stream.of_list [ 1; 2; 3; 4 ]
    |> Pipe.Stream.scan_filter_map 0 (fun acc x ->
        let acc' = acc + x in
        let out = if x = 4 then Some acc' else None in
        (acc', out))
    |> Pipe.Stream.to_list
  in
  Alcotest.(check (list int))
    "state threaded through skipped steps" [ 10 ] emitted (* 1+2+3+4 = 10 *)

let test_unfold () =
  let first_5_primes =
    Pipe.Stream.unfold
      (fun n ->
        (* Tiny: not-really primes, just odd numbers starting at 2 *)
        if n > 9 then None else Some (n, if n = 2 then 3 else n + 2))
      2
    |> Pipe.Stream.to_list
  in
  Alcotest.(check (list int)) "unfold with termination" [ 2; 3; 5; 7; 9 ] first_5_primes

let test_zip_terminates_with_shorter () =
  let zipped =
    Pipe.Stream.zip (Pipe.Stream.of_list [ 1; 2; 3; 4 ]) (Pipe.Stream.of_list [ "a"; "b" ])
    |> Pipe.Stream.to_list
  in
  Alcotest.(check (list (pair int string))) "zip truncates" [ (1, "a"); (2, "b") ] zipped

let test_lazy_infinite_with_take () =
  let nats = Pipe.Stream.unfold (fun n -> Some (n, n + 1)) 0 in
  let first_ten = nats |> Pipe.Stream.take 10 |> Pipe.Stream.to_list in
  Alcotest.(check (list int)) "lazy take" [ 0; 1; 2; 3; 4; 5; 6; 7; 8; 9 ] first_ten

let test_fold_left () =
  let sum = Pipe.Stream.fold_left ( + ) 0 (Pipe.Stream.of_list [ 1; 2; 3; 4; 5 ]) in
  Alcotest.(check int) "fold sum" 15 sum

let tests =
  [
    ("of_list/to_list roundtrip", `Quick, test_of_list_to_list_roundtrip);
    ("map", `Quick, test_map);
    ("filter_map", `Quick, test_filter_map);
    ("scan_map cumulative sum", `Quick, test_scan_map_cumulative_sum);
    ("scan_map is lazy", `Quick, test_scan_map_lazy);
    ("scan_filter_map gated", `Quick, test_scan_filter_map_gated);
    ( "scan_filter_map state always advances",
      `Quick,
      test_scan_filter_map_state_advances_even_when_not_emitting );
    ("unfold with termination", `Quick, test_unfold);
    ("zip terminates with shorter", `Quick, test_zip_terminates_with_shorter);
    ("infinite with take", `Quick, test_lazy_infinite_with_take);
    ("fold_left", `Quick, test_fold_left);
  ]
