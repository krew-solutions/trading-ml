(** Wire-format projection of {!Paper_broker.Order.Values.Order_kind.t}.

    Cross-BC traffic on the [broker.submit-order-command] command
    channel carries [kind] as this discriminated record (a string
    [type] plus optional price fields). ACL adapters on the receiving
    end parse it back into the strongly-typed domain VO. *)

type t = {
  type_ : string; [@key "type"]
  price : string option;
  stop_price : string option;
  limit_price : string option;
}
[@@deriving yojson]

type domain = Paper_broker.Order.Values.Order_kind.t

val of_domain : domain -> t
(** Lossless projection: every domain variant maps to exactly one
    wire shape. Missing-field validity is the inverse parser's
    concern. *)
