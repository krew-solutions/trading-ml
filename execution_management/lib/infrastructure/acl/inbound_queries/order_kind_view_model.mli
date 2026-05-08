(** Inbound DTO mirror of broker's [Order_kind_view_model]. Used by
    {!Place_order_pm}'s state — the saga needs the kind to forward
    into the {!Submit_order_command} once the reservation lands. *)

type t = {
  type_ : string; [@key "type"]
  price : string option;
  stop_price : string option;
  limit_price : string option;
}
[@@deriving yojson]
