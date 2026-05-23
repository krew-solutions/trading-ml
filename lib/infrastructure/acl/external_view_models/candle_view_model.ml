open Core
include Candle_view_model_t
include Candle_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Candle.t

let to_domain (vm : t) : domain =
  Candle.make
    ~ts:(Datetime.Iso8601.parse vm.ts)
    ~open_:(Decimal.of_string vm.open_) ~high:(Decimal.of_string vm.high)
    ~low:(Decimal.of_string vm.low) ~close:(Decimal.of_string vm.close)
    ~volume:(Decimal.of_string vm.volume)
