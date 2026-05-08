(** Inbound DTO mirror of an order view model. Used by the saga's
    [Order_accepted] inbound mirror. *)

type t = {
  id : string;
  exec_id : string;
  client_order_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : string;
  filled : string;
  remaining : string;
  kind : Order_kind_view_model.t;
  tif : string;
  status : string;
  created_ts : int64;
}
[@@deriving yojson]
