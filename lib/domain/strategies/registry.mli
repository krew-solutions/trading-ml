(** Strategy registry — the only file that needs editing to add a strategy
    to the UI/CLI pickers. Each entry knows how to build a default instance
    and how to describe its tunable parameters. *)

type param =
  | Int of int
  | Float of float
  | Bool of bool
  | String of string

type spec = {
  name : string;
  params : (string * param) list;
  build : (string * param) list -> Strategy.t;
}

val get_int : (string * param) list -> string -> int -> int
val get_float : (string * param) list -> string -> float -> float
val get_bool : (string * param) list -> string -> bool -> bool
val get_string : (string * param) list -> string -> string -> string

val specs : spec list
val composite_specs : spec list
val all_specs : spec list

val find : string -> spec option
val names : unit -> string list
