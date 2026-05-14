(** Domain Event: paper_broker accepted a freshly-submitted order
    into its working book. Emitted by {!Order.make} on every
    successful construction. *)

type t = {
  id : string;
  client_order_id : string;
  instrument : Core.Instrument.t;
  side : Core.Side.t;
  quantity : Decimal.t;
  created_ts : int64;
}
