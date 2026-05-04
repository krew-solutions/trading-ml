type t = {
  alpha_source_id : string;
  instrument : string;
  direction : string;
  strength : float;
  price : string;
  occurred_at : string;
}
[@@deriving yojson]
