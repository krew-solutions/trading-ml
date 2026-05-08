open Core

type t = { ticker : string; venue : string; isin : string option; board : string option }
[@@deriving yojson]

type domain = Instrument.t

let of_domain (i : domain) : t =
  {
    ticker = Ticker.to_string (Instrument.ticker i);
    venue = Mic.to_string (Instrument.venue i);
    isin = Option.map Isin.to_string (Instrument.isin i);
    board = Option.map Board.to_string (Instrument.board i);
  }
