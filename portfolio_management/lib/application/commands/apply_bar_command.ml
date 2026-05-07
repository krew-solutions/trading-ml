type candle_dto = {
  ts : string;
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

type t = { instrument : string; timeframe : string; candle : candle_dto }
[@@deriving yojson]
