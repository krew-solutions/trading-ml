(** Runtime registry of indicator factories. Lets the UI list indicators and
    build new ones by name with typed parameters. *)

type param = Int of int | Float of float

type spec = {
  name : string;
  params : (string * param) list;
  build : (string * param) list -> Indicator.t;
}

val get_int : (string * param) list -> string -> int -> int
val get_float : (string * param) list -> string -> float -> float
val specs : spec list
val find : string -> spec option
val names : unit -> string list
