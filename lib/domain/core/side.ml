type t = Buy | Sell

let to_string = function Buy -> "BUY" | Sell -> "SELL"
let of_string = function
  | "BUY" | "buy" | "Buy" -> Buy
  | "SELL" | "sell" | "Sell" -> Sell
  | s -> invalid_arg ("Side.of_string: " ^ s)

let opposite = function Buy -> Sell | Sell -> Buy
let sign = function Buy -> 1 | Sell -> -1

let yojson_of_t t = `String (to_string t)
let t_of_yojson = function
  | `String s -> of_string s
  | j -> invalid_arg ("Side.t_of_yojson: " ^ Yojson.Safe.to_string j)
