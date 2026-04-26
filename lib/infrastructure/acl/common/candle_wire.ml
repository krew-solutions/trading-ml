open Core

let of_yojson_flex (j : Yojson.Safe.t) : Candle.t =
  let open Yojson.Safe.Util in
  let find names =
    List.fold_left
      (fun acc k ->
        match acc with
        | `Null -> member k j
        | v -> v)
      `Null names
  in
  let ts =
    match find [ "timestamp"; "time"; "t"; "ts" ] with
    | `String s -> Infra_common.Iso8601.parse s
    | `Int n -> Int64.of_int n
    | `Intlit s -> Int64.of_string s
    | _ -> 0L
  in
  let dec names = try Decimal_wire.of_yojson_flex (find names) with _ -> Decimal.zero in
  Candle.make ~ts
    ~open_:(dec [ "open"; "o" ])
    ~high:(dec [ "high"; "h" ])
    ~low:(dec [ "low"; "l" ])
    ~close:(dec [ "close"; "c" ])
    ~volume:(dec [ "volume"; "vol"; "v"; "total_volume" ])
