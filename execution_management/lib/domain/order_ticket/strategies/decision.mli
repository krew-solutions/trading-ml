(** Strategy decision — what the strategy proposes after processing
    one Input. The aggregate enforces global invariants and decides
    whether to honour each proposal; the strategy is advisory.

    Three components:
    - [submit]: new placements to dispatch to broker. Each one
      carries quantity / kind / tif; the aggregate stamps a fresh
      [Placement_id] before publishing the Placement_dispatched
      domain event.
    - [cancel]: placement_ids of outstanding placements the
      strategy wants cancelled (Iceberg may abandon an unfilled
      visible chunk; IS may re-route on adverse price movement).
    - [terminal]: classifies the strategy's view of the ticket's
      future. [Continue] is the default; [Completed] signals "I've
      emitted all the work I intend to" (cumulative fill drives the
      aggregate's terminal transition once [Σ filled = total]);
      [Failed reason] signals "I gave up" (e.g. broker repeatedly
      rejected, retry budget exhausted). *)

(*@ function dec_raw (d : Decimal.t) : integer *)

type submit_request = {
  quantity : Decimal.t;
  kind : Values.Order_kind.t;
  tif : Values.Tif.t;
}

(*@ function submit_quantity (r : submit_request) : integer = dec_raw r.quantity *)

type terminal =
  | Continue
  | Completed
  | Failed of string

type t = {
  submit : submit_request list;
  cancel : Placement.Values.Placement_id.t list;
  terminal : terminal;
}

val empty : t
(** No work, no cancels, [Continue]. *)
(*@ d = empty
    ensures d.submit = []
    ensures d.cancel = []
    ensures d.terminal = Continue *)
