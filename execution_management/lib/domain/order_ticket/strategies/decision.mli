(** Strategy decision — what the strategy proposes after processing
    one Input. The aggregate enforces global invariants and decides
    whether to honour each proposal; the strategy is advisory. *)

(*@ function dec_raw (d : Decimal.t) : integer *)

type submit_request = {
  quantity : Decimal.t;
  kind : Placement.Values.Order_kind.t;
  tif : Placement.Values.Tif.t;
}

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
(*@ d = empty
    ensures d.submit = []
    ensures d.cancel = []
    ensures d.terminal = Continue *)
