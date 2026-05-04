(** Read-model DTO for {!Common.Order.t}. *)

type t = {
  id : string;
  exec_id : string;
  client_order_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : string;  (** Decimal string accepted by {!Decimal.of_string}. *)
  filled : string;
  remaining : string;
  kind : Order_kind_view_model.t;
  tif : string;
  status : string;
  created_ts : int64;
}
[@@deriving yojson]

type domain = Common.Order.t

val of_domain : domain -> t
