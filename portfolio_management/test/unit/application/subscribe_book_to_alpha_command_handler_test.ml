(** Unit tests for {!Subscribe_book_to_alpha_command_handler}. *)

module Pm = Portfolio_management
module SBA = Portfolio_management_commands.Subscribe_book_to_alpha_command
module H = Portfolio_management_commands.Subscribe_book_to_alpha_command_handler

let well_formed_cmd ?(alpha = "momentum-1") ?(inst = "SBER@MISX") ?(book = "book-α") () :
    SBA.t =
  { alpha_source_id = alpha; instrument = inst; book_id = book }

let make_registry () =
  let bag : Pm.Common.Alpha_subscription.t list ref = ref [] in
  let persist sub =
    if List.exists (Pm.Common.Alpha_subscription.equal sub) !bag then ()
    else bag := sub :: !bag
  in
  (bag, persist)

let expect_validation_failure cmd =
  let _, persist = make_registry () in
  match H.handle ~persist_subscription:persist cmd with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected Error"

let test_happy_path_persists () =
  let bag, persist = make_registry () in
  match H.handle ~persist_subscription:persist (well_formed_cmd ()) with
  | Ok () ->
      Alcotest.(check int) "one subscription" 1 (List.length !bag);
      let sub = List.hd !bag in
      Alcotest.(check string)
        "alpha source" "momentum-1"
        (Pm.Common.Alpha_source_id.to_string sub.alpha_source_id);
      Alcotest.(check string) "book" "book-α" (Pm.Common.Book_id.to_string sub.book_id)
  | Error _ -> Alcotest.fail "expected Ok"

let test_duplicate_is_idempotent () =
  let bag, persist = make_registry () in
  let _ = H.handle ~persist_subscription:persist (well_formed_cmd ()) in
  let _ = H.handle ~persist_subscription:persist (well_formed_cmd ()) in
  Alcotest.(check int) "still one" 1 (List.length !bag)

let test_different_triplets_coexist () =
  let bag, persist = make_registry () in
  let _ = H.handle ~persist_subscription:persist (well_formed_cmd ~book:"book-α" ()) in
  let _ = H.handle ~persist_subscription:persist (well_formed_cmd ~book:"book-β" ()) in
  Alcotest.(check int) "both kept" 2 (List.length !bag)

let test_rejects_empty_alpha () = expect_validation_failure (well_formed_cmd ~alpha:"" ())

let test_rejects_malformed_instrument () =
  expect_validation_failure (well_formed_cmd ~inst:"bad" ())

let test_rejects_empty_book () = expect_validation_failure (well_formed_cmd ~book:"" ())

let tests =
  [
    Alcotest.test_case "happy path persists subscription" `Quick test_happy_path_persists;
    Alcotest.test_case "duplicate command is idempotent" `Quick
      test_duplicate_is_idempotent;
    Alcotest.test_case "different triplets coexist" `Quick test_different_triplets_coexist;
    Alcotest.test_case "rejects empty alpha_source_id" `Quick test_rejects_empty_alpha;
    Alcotest.test_case "rejects malformed instrument" `Quick
      test_rejects_malformed_instrument;
    Alcotest.test_case "rejects empty book_id" `Quick test_rejects_empty_book;
  ]
