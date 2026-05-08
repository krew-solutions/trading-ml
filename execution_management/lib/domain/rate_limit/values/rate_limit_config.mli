(** Rolling-window rate-limit configuration: at most [max_orders]
    submissions in any [window_seconds]-wide trailing window.

    Invariants:
    - [max_orders ≥ 0];
    - [window_seconds > 0]. *)

type t = private { max_orders : int; window_seconds : float }

val make : max_orders:int -> window_seconds:float -> t
(*@ c = make ~max_orders ~window_seconds
    requires max_orders >= 0
    requires window_seconds > 0.0
    ensures c.max_orders = max_orders
    ensures c.window_seconds = window_seconds *)

val max_orders : t -> int
val window_seconds : t -> float
