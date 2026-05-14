(** Wire-format command: a new OHLCV bar has been observed for an
    instrument. Wire-byte-equivalent to the
    [portfolio_management.Apply_bar_command] so the same
    [broker.bar-updated] channel can be consumed by either BC. *)

type candle_dto = {
  ts : string;  (** ISO-8601. *)
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

type t = { instrument : string; timeframe : string; candle : candle_dto }
[@@deriving yojson]
