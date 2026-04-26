(** Functional stream abstraction built on {!Stdlib.Seq}.

    The domain speaks in terms of lazy, pull-driven sequences: a
    {!Stream.t} is a function that on each invocation produces either
    [Nil] (end of stream) or [Cons (x, rest)]. This is exactly
    {!Stdlib.Seq.t} — this module does not redefine it, only adds the
    one primitive that isn't in stdlib ({!scan_map}) and re-exports
    the combinators we actually use, so callers program against a
    single, small surface.

    Key use case: the same Mealy-style transducer drives both
    {!Engine.Backtest} (with [of_list] → transforms → [to_list]) and
    a live trading loop (with an Eio-backed source → [iter]). See
    [lib/infrastructure/eio_stream/] for the Eio adapter; this
    module stays pure and Eio-free so it belongs in the domain.

    Termination: a stream is finite iff its producer eventually
    returns [Nil]. Live sources built over [Eio.Stream.take] are
    effectively infinite — consume them with {!iter}, not
    {!to_list}. *)

type 'a t = 'a Seq.t

(** {1 Construction} *)

val empty : 'a t
val cons : 'a -> 'a t -> 'a t
val of_list : 'a list -> 'a t

val unfold : ('state -> ('a * 'state) option) -> 'state -> 'a t
(** Generate a stream from a seed. [f state] produces the next
    element and the updated seed, or [None] to terminate. *)

(** {1 Transforms} *)

val map : ('a -> 'b) -> 'a t -> 'b t
val filter : ('a -> bool) -> 'a t -> 'a t
val filter_map : ('a -> 'b option) -> 'a t -> 'b t
val take : int -> 'a t -> 'a t
val zip : 'a t -> 'b t -> ('a * 'b) t

val scan_map : 'state -> ('state -> 'a -> 'state * 'b) -> 'a t -> 'b t
(** Mealy-transducer: thread [state] through the stream, emitting
    one output per input. The missing-from-stdlib primitive —
    {!Seq.scan} emits only accumulator snapshots, not a distinct
    output per step, and {!Seq.fold_left} discards the shape
    entirely.

    [scan_map state0 step input] evaluates lazily: each forced node
    of the output runs [step] once on the corresponding input. *)

val scan_filter_map : 'state -> ('state -> 'a -> 'state * 'b option) -> 'a t -> 'b t
(** Like {!scan_map}, but the step may choose not to emit (returns
    [None]). State still advances either way — useful for gated
    pipelines (e.g. "only emit an order on non-Hold signals, but
    always advance strategy state"). *)

(** {1 Consumption} *)

val to_list : 'a t -> 'a list
(** Materialise a finite stream. Loops forever on an infinite one. *)

val iter : ('a -> unit) -> 'a t -> unit
(** Consume with side effects. Returns only on [Nil]; loops forever
    on an infinite stream. *)

val fold_left : ('acc -> 'a -> 'acc) -> 'acc -> 'a t -> 'acc
(** Reduce a finite stream to a single value. *)
