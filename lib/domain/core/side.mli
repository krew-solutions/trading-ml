(** Trade direction. *)

type t = Buy | Sell

val to_string : t -> string
val of_string : string -> t
val opposite : t -> t
val sign : t -> int

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
