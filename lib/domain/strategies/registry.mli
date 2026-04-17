(** Strategy registry -- the only file that needs editing to add a strategy
    to the UI/CLI pickers. Each entry knows how to build a default instance
    and how to describe its tunable parameters. *)

(** A single parameter value. *)
type param =
  | Int of int
  | Float of float
  | Bool of bool

(** Specification of a registered strategy: its name, default parameter
    list, and a builder that accepts overridden parameters. *)
type spec = {
  name : string;
  params : (string * param) list;
  build : (string * param) list -> Strategy.t;
}

(** All registered strategy specifications. *)
val specs : spec list

(** [find name] returns the specification for the named strategy, if any. *)
val find : string -> spec option

(** List of all registered strategy names. *)
val names : unit -> string list
