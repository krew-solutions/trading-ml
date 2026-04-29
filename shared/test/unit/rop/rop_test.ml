(** Tests for the Wlaschin-canonical adapters/combinators added to
    {!Rop}: [switch], [tee], [try_catch], [double_map], [>>=], [>=>]. *)

let test_switch_lifts_to_success () =
  let f x = x + 1 in
  match Rop.switch f 41 with
  | Ok 42 -> ()
  | Ok n -> Alcotest.failf "got Ok %d" n
  | Error _ -> Alcotest.fail "switch must always succeed"

let test_tee_runs_side_effect_and_passes_through () =
  let captured = ref None in
  let result = Rop.tee (fun x -> captured := Some x) 7 in
  Alcotest.(check int) "value passed through" 7 result;
  Alcotest.(check (option int)) "side effect ran" (Some 7) !captured

let test_try_catch_wraps_success () =
  let f x = x * 2 in
  match Rop.try_catch f (fun _ -> "boom") 21 with
  | Ok 42 -> ()
  | Ok n -> Alcotest.failf "got Ok %d" n
  | Error _ -> Alcotest.fail "no exception => Ok"

let test_try_catch_routes_exception_to_failure () =
  let f _ = failwith "kaboom" in
  match Rop.try_catch f (fun e -> Printexc.to_string e) () with
  | Ok _ -> Alcotest.fail "exception must surface as Failure"
  | Error [ msg ] ->
      Alcotest.(check bool) "handler captured exception" true (String.length msg > 0)
  | Error _ -> Alcotest.fail "expected single-element error list"

let test_double_map_on_success () =
  let r = Rop.succeed 10 in
  match Rop.double_map (fun x -> x * 2) (fun e -> e ^ "!") r with
  | Ok 20 -> ()
  | _ -> Alcotest.fail "success branch not transformed correctly"

let test_double_map_on_failure_per_element () =
  let r : (int, string) Rop.t = Error [ "a"; "b"; "c" ] in
  match Rop.double_map (fun x -> x) (fun e -> e ^ "!") r with
  | Error [ "a!"; "b!"; "c!" ] -> ()
  | Error other -> Alcotest.failf "got [%s]" (String.concat "; " other)
  | Ok _ -> Alcotest.fail "Ok must stay Ok... but we expected Error here"

let test_bind_infix_is_bind () =
  let open Rop in
  let f x = if x > 0 then succeed (x * 10) else fail "neg" in
  match succeed 4 >>= f with
  | Ok 40 -> ()
  | _ -> Alcotest.fail "bind via >>= should match plain bind"

let test_kleisli_composes_two_switches () =
  let f x = if x >= 0 then Rop.succeed (x + 1) else Rop.fail "neg-f" in
  let g x = if x < 100 then Rop.succeed (x * 2) else Rop.fail "big-g" in
  let h = Rop.( >=> ) f g in
  match h 5 with
  | Ok 12 -> ()
  | _ -> Alcotest.fail "Kleisli composition should chain f then g"

let test_kleisli_short_circuits_on_first_failure () =
  let f _ = Rop.fail "stop-at-f" in
  let g_called = ref false in
  let g x =
    g_called := true;
    Rop.succeed x
  in
  let h = Rop.( >=> ) f g in
  match h () with
  | Error [ "stop-at-f" ] -> Alcotest.(check bool) "g not called" false !g_called
  | _ -> Alcotest.fail "first-failure must short-circuit"

let test_either_dispatches_branches () =
  let s_called = ref 0 in
  let f_called = ref 0 in
  let success x =
    incr s_called;
    `S x
  in
  let failure e =
    incr f_called;
    `F e
  in
  let r1 = Rop.either success failure (Rop.succeed 42) in
  let r2 = Rop.either success failure (Rop.fail "boom") in
  Alcotest.(check int) "success branch ran once" 1 !s_called;
  Alcotest.(check int) "failure branch ran once" 1 !f_called;
  match (r1, r2) with
  | `S 42, `F [ "boom" ] -> ()
  | _ -> Alcotest.fail "either should route to the corresponding branch"

let test_plus_both_success_merges () =
  let s1 _ = Rop.succeed [ 1 ] in
  let s2 _ = Rop.succeed [ 2 ] in
  let p = Rop.plus ( @ ) ( @ ) s1 s2 in
  match p () with
  | Ok [ 1; 2 ] -> ()
  | _ -> Alcotest.fail "plus should add successes via add_success"

let test_plus_both_failure_accumulates () =
  let s1 _ : (int, string) Rop.t = Rop.fail "a" in
  let s2 _ : (int, string) Rop.t = Rop.fail "b" in
  let p = Rop.plus (fun a _ -> a) ( @ ) s1 s2 in
  match p () with
  | Error [ "a"; "b" ] -> ()
  | Error other -> Alcotest.failf "got [%s]" (String.concat "; " other)
  | Ok _ -> Alcotest.fail "expected accumulated failure"

let test_plus_one_failure_short_circuits_to_it () =
  let s1 _ = Rop.succeed 1 in
  let s2 _ : (int, string) Rop.t = Rop.fail "b" in
  match Rop.plus ( + ) ( @ ) s1 s2 () with
  | Error [ "b" ] -> ()
  | _ -> Alcotest.fail "single failure should surface as that failure"

let tests =
  [
    ("either dispatches branches", `Quick, test_either_dispatches_branches);
    ("switch lifts to success", `Quick, test_switch_lifts_to_success);
    ( "tee runs side effect and passes through",
      `Quick,
      test_tee_runs_side_effect_and_passes_through );
    ("try_catch wraps success", `Quick, test_try_catch_wraps_success);
    ( "try_catch routes exception to failure",
      `Quick,
      test_try_catch_routes_exception_to_failure );
    ("double_map on success", `Quick, test_double_map_on_success);
    ("double_map on failure per element", `Quick, test_double_map_on_failure_per_element);
    ("plus both-success merges", `Quick, test_plus_both_success_merges);
    ("plus both-failure accumulates", `Quick, test_plus_both_failure_accumulates);
    ( "plus one failure short-circuits to it",
      `Quick,
      test_plus_one_failure_short_circuits_to_it );
    (">>= is bind", `Quick, test_bind_infix_is_bind);
    (">=> composes two switches", `Quick, test_kleisli_composes_two_switches);
    ( ">=> short-circuits on first failure",
      `Quick,
      test_kleisli_short_circuits_on_first_failure );
  ]
