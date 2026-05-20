open Core

type t = { instrument : Instrument.t; bid : Decimal.t; ask : Decimal.t; ts : int64 }

let parse (j : Yojson.Safe.t) : t option =
  let open Yojson.Safe.Util in
  let payload = Payload.unwrap (member "payload" j) in
  match member "quote" payload with
  | `List (q :: _) ->
      let instrument = Instrument.of_qualified (member "symbol" q |> to_string) in
      let bid = Dto.decimal_field "bid" q in
      let ask = Dto.decimal_field "ask" q in
      let ts =
        match member "timestamp" q with
        | `String s -> Datetime.Iso8601.parse s
        | `Int n -> Int64.of_int n
        | _ -> 0L
      in
      Some { instrument; bid; ask; ts }
  | _ -> None
