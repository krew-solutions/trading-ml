(** Lightweight Gherkin-style BDD eDSL over Alcotest.

    Embedded DSL (no [.feature] file parsing) — Given/When/Then step
    builders compose into scenarios with shared mutable context. *)

type 'ctx step = 'ctx -> 'ctx

let given (description : string) (f : 'ctx -> 'ctx) : 'ctx step =
 fun ctx ->
  ignore description;
  f ctx

let when_ (description : string) (f : 'ctx -> 'ctx) : 'ctx step =
 fun ctx ->
  ignore description;
  f ctx

let then_ (description : string) (f : 'ctx -> unit) : 'ctx step =
 fun ctx ->
  ignore description;
  f ctx;
  ctx

let and_ = given

let scenario (name : string) (make_ctx : unit -> 'ctx) (steps : 'ctx step list) =
  Alcotest.test_case name `Quick (fun () ->
      let initial_ctx = make_ctx () in
      ignore (List.fold_left (fun ctx step -> step ctx) initial_ctx steps))

let feature (name : string) (scenarios : unit Alcotest.test_case list) = (name, scenarios)
