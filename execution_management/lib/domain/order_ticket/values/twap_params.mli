(** TWAP — Time-Weighted Average Price — parameters.

    Splits the trader's [total_quantity] into [n_slices] equal
    pieces (the last slice carries the integer-division residue)
    and emits one per scheduled tick across [window_seconds]
    starting at [start_at].

    Invariants:
    - [n_slices > 0];
    - [window_seconds > 0];
    - [start_at] is a wall-clock instant in seconds since epoch.
      The strategy compares incoming [Tick { now }] against
      [start_at + i × (window_seconds / n_slices)] in seconds, so
      callers must supply [start_at] on the same clock as ticks. *)

type t = private { n_slices : int; window_seconds : int; start_at : int64 }

val make : n_slices:int -> window_seconds:int -> start_at:int64 -> t
(*@ r = make ~n_slices ~window_seconds ~start_at
    requires n_slices > 0
    requires window_seconds > 0
    ensures r.n_slices = n_slices
    ensures r.window_seconds = window_seconds
    ensures r.start_at = start_at *)
