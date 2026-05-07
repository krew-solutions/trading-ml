type bar_dto = {
  ts : int64;
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

type t = { instrument : string; timeframe : string; bar : bar_dto } [@@deriving yojson]
