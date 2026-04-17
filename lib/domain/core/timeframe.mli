(** Bar aggregation period. *)

type t =
  | M1 | M5 | M15 | M30
  | H1 | H4
  | D1 | W1 | MN1

val to_seconds : t -> int
val to_string : t -> string
val of_string : string -> t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
