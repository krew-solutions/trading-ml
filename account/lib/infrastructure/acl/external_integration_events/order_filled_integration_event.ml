type t = {
  correlation_id : string;
  reservation_id : int;
  quantity : string;
  price : string;
  fee : string;
}
[@@deriving yojson]
