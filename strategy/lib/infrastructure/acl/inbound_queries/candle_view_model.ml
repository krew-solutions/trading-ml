type t = {
  ts : string;
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]
