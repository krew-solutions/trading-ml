(** Wire-format command: client submits a new working order to
    paper_broker's matching engine.

    Carries the same shape as the broker BC's local
    [submit_order_command] so the same on-bus channel can be
    handled by either backend depending on deployment. paper_broker
    treats [reservation_id] as an opaque round-trip token; it
    never reads or interprets it. *)

type t = {
  correlation_id : string;
  reservation_id : int;
  symbol : string;
      (** Qualified symbol [TICKER@MIC] (with optional [/BOARD]
          suffix), parsed by the receiver. *)
  side : string;  (** ["BUY"] | ["SELL"]. *)
  quantity : string;  (** Decimal string; receiver enforces [> 0]. *)
  kind : Paper_broker_queries.Order_kind_view_model.t;
  tif : string;  (** ["GTC"] | ["DAY"] | ["IOC"] | ["FOK"]. *)
}
[@@deriving yojson]
