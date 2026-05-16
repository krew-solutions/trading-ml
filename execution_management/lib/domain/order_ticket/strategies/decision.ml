type submit_request = {
  quantity : Decimal.t;
  kind : Values.Order_kind.t;
  tif : Values.Tif.t;
}

type terminal = Continue | Completed | Failed of string

type t = {
  submit : submit_request list;
  cancel : Placement.Values.Placement_id.t list;
  terminal : terminal;
}

let empty = { submit = []; cancel = []; terminal = Continue }
