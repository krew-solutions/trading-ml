open Core
include Instrument_view_model_t
include Instrument_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Instrument.t

let to_domain (vm : t) : domain =
  Instrument.make ~ticker:(Ticker.of_string vm.ticker) ~venue:(Mic.of_string vm.venue)
    ?isin:(Option.map Isin.of_string vm.isin)
    ?board:(Option.map Board.of_string vm.board)
    ()
