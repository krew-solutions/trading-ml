(** Read-model DTO for {!Core.Order.t}. *)

type t = {
  id : string;
  exec_id : string;
  client_order_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : float;
  filled : float;
  remaining : float;
  kind : Order_kind_view_model.t;
  tif : string;
  status : string;
  created_ts : int64;
}
[@@deriving yojson]

type domain = Core.Order.t

val of_domain : domain -> t
