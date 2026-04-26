(** Railway-Oriented Programming: accumulating Result.

    Scott Wlaschin's two-track pattern (fsharpforfunandprofit.com/rop)
    realised as a thin layer over the stdlib {!Stdlib.Result}. The
    Error branch always carries a [list] so independent failures
    from parallel validations combine without loss via
    {!apply}/{!both} — e.g. a form with bad symbol AND bad side
    AND negative quantity reports all three problems together,
    not one per round-trip.

    Two sets of sugar for pipeline composition:

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

val succeed : 'a -> ('a, 'err) t
(** [Ok x]. *)

val fail : 'err -> ('a, 'err) t
(** [Error [e]] — single-element failure list. *)

val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
(** Apply a pure function inside the Success track. *)

val apply : ('a -> 'b, 'err) t -> ('a, 'err) t -> ('b, 'err) t
(** Apply a wrapped function to a wrapped value. On two Errors,
    concatenates their lists — this is the core of accumulation. *)

val bind : ('a, 'err) t -> ('a -> ('b, 'err) t) -> ('b, 'err) t
(** Monadic bind: short-circuit on first Error. *)

val both : ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
(** Pair two results, accumulating errors if both fail. Plumbing
    behind [and+]. *)

val of_result : ('a, 'err) result -> ('a, 'err) t
(** Lift a stdlib Result into Rop by wrapping the single error
    in a singleton list. *)

val ( <!> ) : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
(** Infix alias for {!map}. Applicative entry point: lifts a
    plain function into the Result context. *)

val ( <*> ) : ('a -> 'b, 'err) t -> ('a, 'err) t -> ('b, 'err) t
(** Infix alias for {!apply}. Each additional argument in an
    applicative chain. *)

val ( let+ ) : ('a, 'err) t -> ('a -> 'b) -> ('b, 'err) t
(** Applicative let-binding. Use with [and+] for parallel
    validations; errors from every branch accumulate. *)

val ( and+ ) : ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
(** Applicative join — see {!both}. *)

val ( let* ) : ('a, 'err) t -> ('a -> ('b, 'err) t) -> ('b, 'err) t
(** Monadic let-binding. Short-circuits on first Error. Use for
    pipelines where a later step depends on an earlier step's
    success value. *)
