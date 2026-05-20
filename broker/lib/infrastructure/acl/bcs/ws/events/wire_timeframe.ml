open Core

let of_string : string -> Timeframe.t option = function
  | "M1" -> Some M1
  | "M5" -> Some M5
  | "M15" -> Some M15
  | "M30" -> Some M30
  | "H1" -> Some H1
  | "H4" -> Some H4
  | "D" -> Some D1
  | "W" -> Some W1
  | "MN" -> Some MN1
  | _ -> None
