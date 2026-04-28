(** Unit test runner for shared kernel. Mirrors {!shared/lib/}. *)

let () =
  Alcotest.run "trading-shared-unit"
    [ ("command_bus", Command_bus_test.tests); ("event_bus", Event_bus_test.tests) ]
