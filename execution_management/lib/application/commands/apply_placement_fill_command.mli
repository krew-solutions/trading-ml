(** Command: broker reported a fill leg on a placement.
    Issued in-process by the ACL handler for
    {!Broker.Trade_executed_integration_event}. *)

type t = {
  ticket_id : int;
  placement_id : int;
  fill_quantity : string;
  fill_price : string;
  fee : string;
  fill_ts : int64;
}
