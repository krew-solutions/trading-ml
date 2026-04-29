(** Railway-Oriented Programming: accumulating Result.

    Scott Wlaschin's two-track pattern (fsharpforfunandprofit.com/rop)
    realised as a thin layer over the stdlib {!Stdlib.Result}.

    {1 Deviations from Wlaschin's canonical F# version}

    - Failure branch carries a [list], not a single value
      ([type ('a, 'err) t = ('a, 'err list) result]). Required
      so independent failures from parallel validations combine
      without loss via {!apply}/{!both}/{!plus} — e.g. a form
      with bad symbol AND bad side AND negative quantity reports
      all three problems together. Knock-on effects: {!plus}
      takes [add_failure : 'e list -> 'e list -> 'e list] (not
      [single -> single -> single]); {!double_map} maps the
      [failure_fn] element-wise across the error list.
    - {!bind} keeps OCaml's stdlib argument order (two-track
      first, switch second) for [let*] compatibility, instead of
      Wlaschin's F# order (switch first). The end-user-facing
      {!(>>=)} and {!(>=>)} pipe identically to F#.
    - The applicative pieces ({!apply}, {!both}, {!(<*>)},
      [let+]/[and+]) are extensions Wlaschin's toolkit doesn't
      cover; they exploit the list-failure invariant for
      accumulation.

    {1 Sugar for pipeline composition}

    - [let+]/[and+]: applicative — parallel branches, errors
      accumulated. Use for validating many independent fields.
    - [let*]: monadic — sequential branches, first error short-
      circuits. Use when step N depends on result of step N-1
      (e.g. validate → fetch DB row → update), because there's
      no point doing DB work after validation failed.

    Mix freely: a workflow can validate applicatively, then bind
    into fetch, then bind into save, with each binding picking
    the appropriate semantics. *)

type ('a, 'err) t = ('a, 'err list) result
(** Invariant: the Error branch carries a non-empty list of
    errors. This is a {i type alias} for stdlib Result so values
    pattern-match with plain [Ok] / [Error]. *)

(** {1 Constructors} *)

val succeed : 'a -> ('a, 'err) t
(** [Ok x]. Wlaschin's [succeed] / [return] / [pure]. *)

val fail : 'err -> ('a, 'err) t
(** [Error [e]] — single-element failure list. Wlaschin's [fail]. *)

(** {1 Core eliminator}

    All other adapters are defined in terms of {!either}, mirroring
    the "complete code" section of Wlaschin's article. *)

val either : ('a -> 'b) -> ('err list -> 'b) -> ('a, 'err) t -> 'b
(** Apply [success_fn] on the Success branch or [failure_fn] on
    the Failure branch. Wlaschin's [either]. *)

(** {1 Track adapters and combinators (Wlaschin's toolkit, p.27)}

    F#'s [>>] (normal function composition) is intentionally
    omitted — it isn't Result-specific, and OCaml's stdlib carries
    {!Fun.compose} for the same purpose. *)

val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
(** Apply a pure function on the Success track. Wlaschin's [map]. *)

val bind : ('a, 'err) t -> ('a -> ('b, 'err) t) -> ('b, 'err) t
(** Monadic bind: short-circuit on first Error. Wlaschin's [bind]
    with arguments flipped to OCaml order (two-track first). *)

val switch : ('a -> 'b) -> 'a -> ('b, 'err) t
(** Lift a plain one-track function into a switch (always-success).
    Wlaschin's [switch]. *)

val tee : ('a -> unit) -> 'a -> 'a
(** Turn a dead-end side-effecting function (log, persist) into a
    one-track pass-through; the input flows through unchanged
    after the side effect runs. Wlaschin's [tee] / Unix [tee] /
    "[tap]" in some libraries. *)

val try_catch : ('a -> 'b) -> (exn -> 'err) -> 'a -> ('b, 'err) t
(** Lift an exception-throwing function into a switch: any
    exception is routed through [exn_handler] onto the Failure
    track. Wlaschin's [tryCatch]. *)

val double_map : ('a -> 'b) -> ('err -> 'err2) -> ('a, 'err) t -> ('b, 'err2) t
(** Bifunctor map: apply [success_fn] on the Success track and
    [failure_fn] element-wise on every error in the Failure list.
    Wlaschin's [doubleMap] / "[bimap]" in many libraries. *)

val plus :
  ('a -> 'a -> 'a) ->
  ('err list -> 'err list -> 'err list) ->
  ('x -> ('a, 'err) t) ->
  ('x -> ('a, 'err) t) ->
  'x ->
  ('a, 'err) t
(** Combine two switch functions in "parallel" over the same
    input: success values are merged via [add_success], failure
    lists via [add_failure]. Wlaschin's [plus] (a.k.a. [++],
    [<+>]). The Wlaschin'ian [&&&] for validation falls out as
    [plus (fun a _ -> a) ( @ )]. *)

(** {1 Applicative extensions (no Wlaschin counterpart)} *)

val apply : ('a -> 'b, 'err) t -> ('a, 'err) t -> ('b, 'err) t
(** Apply a wrapped function to a wrapped value. On two Errors,
    concatenates their lists — this is the core of accumulation. *)

val both : ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
(** Pair two results, accumulating errors if both fail. Plumbing
    behind [and+]. *)

val of_result : ('a, 'err) result -> ('a, 'err) t
(** Lift a stdlib Result into Rop by wrapping the single error
    in a singleton list. *)

(** {1 Operators} *)

val ( &&& ) : ('x -> ('a, 'err) t) -> ('x -> ('a, 'err) t) -> 'x -> ('a, 'err) t
(** Validation-flavoured {!plus}: success values from both
    branches are assumed equivalent (returns the first), failure
    lists are concatenated. Wlaschin's [&&&]; he recommends
    defining it locally in each validation module rather than
    globally — kept here for convenience, override locally if a
    custom merge is needed. *)

val ( <!> ) : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
(** Infix alias for {!map}. Applicative entry point: lifts a
    plain function into the Result context. *)

val ( <*> ) : ('a -> 'b, 'err) t -> ('a, 'err) t -> ('b, 'err) t
(** Infix alias for {!apply}. Each additional argument in an
    applicative chain. *)

val ( >>= ) : ('a, 'err) t -> ('a -> ('b, 'err) t) -> ('b, 'err) t
(** Infix alias for {!bind} — pipes a two-track value into a
    switch function. Wlaschin's [>>=]. *)

val ( >=> ) : ('a -> ('b, 'err) t) -> ('b -> ('c, 'err) t) -> 'a -> ('c, 'err) t
(** Switch (Kleisli) composition: chain two switch functions into
    a new switch function. Equivalent to [fun x -> f x >>= g].
    Wlaschin's [>=>]. *)

val ( let+ ) : ('a, 'err) t -> ('a -> 'b) -> ('b, 'err) t
(** Applicative let-binding. Use with [and+] for parallel
    validations; errors from every branch accumulate. *)

val ( and+ ) : ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
(** Applicative join — see {!both}. *)

val ( let* ) : ('a, 'err) t -> ('a -> ('b, 'err) t) -> ('b, 'err) t
(** Monadic let-binding. Short-circuits on first Error. Use for
    pipelines where a later step depends on an earlier step's
    success value. *)
