type t = Buy | Sell

let to_string = function
  | Buy -> "BUY"
  | Sell -> "SELL"
let of_string = function
  | "BUY" | "buy" | "Buy" -> Buy
  | "SELL" | "sell" | "Sell" -> Sell
  | s -> invalid_arg ("Side.of_string: " ^ s)

let opposite = function
  | Buy -> Sell
  | Sell -> Buy
let sign = function
  | Buy -> 1
  | Sell -> -1
