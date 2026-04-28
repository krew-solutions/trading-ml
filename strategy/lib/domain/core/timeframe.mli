(** Bar aggregation period. *)

type t = M1 | M5 | M15 | M30 | H1 | H4 | D1 | W1 | MN1

val to_seconds : t -> int
(** Bar length in whole seconds. Always positive. *)
(*@ r = to_seconds t
    ensures r > 0
    ensures match t with
            | M1  -> r = 60
            | M5  -> r = 300
            | M15 -> r = 900
            | M30 -> r = 1800
            | H1  -> r = 3600
            | H4  -> r = 14400
            | D1  -> r = 86400
            | W1  -> r = 604800
            | MN1 -> r = 2592000 *)

val to_string : t -> string

val of_string : string -> t
(** Accepts the canonical tokens ([M1], [M5], …, [MN1]); raises
    [Invalid_argument] on any other input. *)
(*@ r = of_string s
    raises Invalid_argument _ -> true *)
