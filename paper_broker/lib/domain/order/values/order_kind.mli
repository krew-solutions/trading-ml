(** Order kind owned by paper_broker — the local duplicate of the
    submit-time variant (Market / Limit / Stop / Stop_limit). Each
    price field carries a strict-positivity invariant enforced by
    the smart constructors below.

    Cross-BC traffic over [submit_order_command] carries [kind] as
    a string; ACL adapters parse it back into this type. *)

type t = private
  | Market
  | Limit of Decimal.t
  | Stop of Decimal.t
  | Stop_limit of { stop : Decimal.t; limit : Decimal.t }

val market : t

val limit : Decimal.t -> t
(** Raises [Invalid_argument] when [price <= 0]. *)

val stop : Decimal.t -> t
(** Raises [Invalid_argument] when [price <= 0]. *)

val stop_limit : stop:Decimal.t -> limit:Decimal.t -> t
(** Raises [Invalid_argument] when either price is [<= 0]. *)
