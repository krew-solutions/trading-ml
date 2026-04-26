(** Unit tests for {!Token_store}. *)

let test_env_reads_existing_var () =
  (* Reuse a var we're sure exists in the test environment: HOME. *)
  let home = Sys.getenv "HOME" in
  let s = Token_store.env ~name:"HOME" in
  Alcotest.(check (option string)) "HOME read" (Some home) (Token_store.load s)

let test_env_returns_none_when_missing () =
  let s = Token_store.env ~name:"TOKEN_STORE_TEST_MISSING_VAR_12345" in
  Alcotest.(check (option string)) "absent var" None (Token_store.load s)

let test_env_save_is_noop () =
  (* Env store is read-only; save must not throw, and load still reflects
     the underlying var (or absence). *)
  let s = Token_store.env ~name:"TOKEN_STORE_TEST_MISSING_VAR_12345" in
  Token_store.save s "ignored";
  Alcotest.(check (option string)) "still None after save" None (Token_store.load s)

let test_memory_roundtrip () =
  let s = Token_store.memory () in
  Alcotest.(check (option string)) "initial" None (Token_store.load s);
  Token_store.save s "v1";
  Alcotest.(check (option string)) "after save" (Some "v1") (Token_store.load s);
  Token_store.save s "v2";
  Alcotest.(check (option string)) "overwrite" (Some "v2") (Token_store.load s)

let test_memory_with_initial () =
  let s = Token_store.memory ~initial:"seed" () in
  Alcotest.(check (option string)) "seed" (Some "seed") (Token_store.load s)

let tmp_path () =
  let base = try Sys.getenv "TMPDIR" with Not_found -> "/tmp" in
  Filename.concat base
    (Printf.sprintf "token_store_test_%d_%d" (Unix.getpid ())
       (int_of_float (Unix.gettimeofday () *. 1e6)))

let with_tmp f =
  let path = tmp_path () in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path;
      if Sys.file_exists (path ^ ".tmp") then Sys.remove (path ^ ".tmp"))
    (fun () -> f path)

let test_file_returns_none_when_absent () =
  with_tmp (fun path ->
      let s = Token_store.file ~path in
      Alcotest.(check (option string)) "missing → None" None (Token_store.load s))

let test_file_save_and_load () =
  with_tmp (fun path ->
      let s = Token_store.file ~path in
      Token_store.save s "secret-value";
      Alcotest.(check (option string))
        "round-trip" (Some "secret-value") (Token_store.load s))

let test_file_trims_trailing_newline () =
  with_tmp (fun path ->
      (* Simulate a human-edited file with a trailing newline. *)
      Out_channel.with_open_text path (fun oc ->
          Out_channel.output_string oc "from-shell\n");
      let s = Token_store.file ~path in
      Alcotest.(check (option string)) "trimmed" (Some "from-shell") (Token_store.load s))

let test_file_chmod_600 () =
  with_tmp (fun path ->
      let s = Token_store.file ~path in
      Token_store.save s "perm-check";
      let stat = Unix.stat path in
      (* Only owner bits; group/other must be zero. *)
      Alcotest.(check int) "mode = 0o600" 0o600 (stat.st_perm land 0o777))

let test_file_overwrite_is_atomic () =
  with_tmp (fun path ->
      let s = Token_store.file ~path in
      Token_store.save s "first";
      Token_store.save s "second";
      Alcotest.(check (option string)) "newest wins" (Some "second") (Token_store.load s);
      (* No stale tmp left behind. *)
      Alcotest.(check bool) "tmp cleaned up" false (Sys.file_exists (path ^ ".tmp")))

let test_fallback_reads_primary_first () =
  let primary = Token_store.memory ~initial:"primary-val" () in
  let secondary = Token_store.memory ~initial:"secondary-val" () in
  let s = Token_store.fallback primary secondary in
  Alcotest.(check (option string))
    "primary wins" (Some "primary-val") (Token_store.load s)

let test_fallback_falls_through_when_primary_empty () =
  let primary = Token_store.memory () in
  let secondary = Token_store.memory ~initial:"bootstrap" () in
  let s = Token_store.fallback primary secondary in
  Alcotest.(check (option string)) "falls back" (Some "bootstrap") (Token_store.load s)

let test_fallback_save_goes_to_primary_only () =
  let primary = Token_store.memory () in
  let secondary = Token_store.memory ~initial:"seed" () in
  let s = Token_store.fallback primary secondary in
  Token_store.save s "rotated";
  Alcotest.(check (option string))
    "primary now holds rotated" (Some "rotated") (Token_store.load primary);
  Alcotest.(check (option string))
    "secondary untouched" (Some "seed") (Token_store.load secondary)

let tests =
  [
    ("env reads existing var", `Quick, test_env_reads_existing_var);
    ("env returns None when missing", `Quick, test_env_returns_none_when_missing);
    ("env save is no-op", `Quick, test_env_save_is_noop);
    ("memory roundtrip", `Quick, test_memory_roundtrip);
    ("memory with initial", `Quick, test_memory_with_initial);
    ("file returns None when absent", `Quick, test_file_returns_none_when_absent);
    ("file save + load", `Quick, test_file_save_and_load);
    ("file trims trailing newline", `Quick, test_file_trims_trailing_newline);
    ("file chmod 0o600", `Quick, test_file_chmod_600);
    ("file overwrite atomic", `Quick, test_file_overwrite_is_atomic);
    ("fallback primary first", `Quick, test_fallback_reads_primary_first);
    ( "fallback through to secondary",
      `Quick,
      test_fallback_falls_through_when_primary_empty );
    ("fallback save primary only", `Quick, test_fallback_save_goes_to_primary_only);
  ]
