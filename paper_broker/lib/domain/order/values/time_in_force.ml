type t = GTC | DAY | IOC | FOK

let to_string = function
  | GTC -> "GTC"
  | DAY -> "DAY"
  | IOC -> "IOC"
  | FOK -> "FOK"
