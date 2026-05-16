(** ACL-private mapping {[placement_id → client_order_id]} for
    the BCS adapter.

    BCS speaks its own venue identity ([clientOrderId], BCS's
    "UUID format") — a concept that has no place in our model.
    The cross-BC saga key [placement_id : int] is all the
    application layer carries; this store is the bridge between
    the two, scoped to the BCS adapter's lifetime.

    Encapsulated as an explicit module so the eventual swap to a
    persistent backend (rotation-resilient across adapter
    restarts) is a single-file change. Today: in-memory Hashtbl
    with Mutex, lifetime tied to the adapter instance. *)

type t

val create : unit -> t

val record : t -> placement_id:int -> client_order_id:string -> [ `Ok | `Already_exists ]
(** Records the linkage produced by a successful submit. Returns
    [`Already_exists] when [placement_id] is already mapped — a
    saga is expected to mint each placement_id once, so a
    collision indicates a replay or upstream bug. *)

val find_client_order_id : t -> placement_id:int -> string option
(** [None] when no placement is recorded — cancel arrived for an
    order this adapter never placed, or its index has been lost. *)

val find_placement_id : t -> client_order_id:string -> int option
(** Reverse lookup, used by listing paths to surface only our
    own placements (foreign orders are filtered out). *)

val all : t -> (int * string) list
(** Snapshot of every recorded linkage. Order unspecified. *)
