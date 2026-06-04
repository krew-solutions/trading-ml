(** ACL-private mapping {[placement_id → client_order_id]} for the Finam gRPC
    adapter.

    Finam speaks its own venue identity ([client_order_id]) — a concept with no
    place in our model. The cross-BC saga key [placement_id : int] is all the
    application layer carries; this store bridges the two, scoped to the
    adapter's lifetime. An autonomous copy of the REST sibling's store: each
    adapter owns its own, so the two never couple.

    Today: in-memory [Hashtbl] with a [Mutex], lifetime tied to the adapter
    instance. The explicit module keeps the eventual swap to a persistent,
    rotation-resilient backend a single-file change. *)

type t

val create : unit -> t

val record : t -> placement_id:int -> client_order_id:string -> [ `Ok | `Already_exists ]
(** Record the linkage produced by a successful submit. [`Already_exists] when
    [placement_id] is already mapped — a saga mints each placement_id once, so a
    collision indicates a replay or upstream bug. *)

val find_client_order_id : t -> placement_id:int -> string option
(** [None] when no placement is recorded (cancel for an order this adapter never
    placed, or its index was lost). *)

val find_placement_id : t -> client_order_id:string -> int option
(** Reverse lookup, used to surface only our own placements. *)

val all : t -> (int * string) list
(** Snapshot of every recorded linkage. Order unspecified. *)
