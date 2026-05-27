open Core
include Instrument_view_model_t
include Instrument_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Instrument.t

let of_domain (i : domain) : t =
  {
    ticker = Ticker.to_string (Instrument.ticker i);
    venue = Mic.to_string (Instrument.venue i);
    isin = Option.map Isin.to_string (Instrument.isin i);
    board = Option.map Board.to_string (Instrument.board i);
  }
