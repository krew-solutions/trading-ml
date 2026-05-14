(** Domain Event: a working order was cancelled before reaching a
    fill-terminal status. Emitted by {!Order.cancel} on a successful
    transition out of [New] or [Partially_filled]. *)

type t = {
  id : string;
  client_order_id : string;
  instrument : Core.Instrument.t;
  cancelled_ts : int64;
}
