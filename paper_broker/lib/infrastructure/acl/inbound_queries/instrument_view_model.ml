type t = { ticker : string; venue : string; isin : string option; board : string option }
[@@deriving yojson]
