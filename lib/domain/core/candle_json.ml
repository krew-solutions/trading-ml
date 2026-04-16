(** JSON encoding kept separate so [Candle.mli] remains Gospel-checkable. *)

let yojson_of_t (c : Candle.t) : Yojson.Safe.t =
  `Assoc [
    "ts", `Intlit (Int64.to_string c.Candle.ts);
    "open", Decimal_json.yojson_of_t c.open_;
    "high", Decimal_json.yojson_of_t c.high;
    "low", Decimal_json.yojson_of_t c.low;
    "close", Decimal_json.yojson_of_t c.close;
    "volume", Decimal_json.yojson_of_t c.volume;
  ]

let t_of_yojson (j : Yojson.Safe.t) : Candle.t =
  let open Yojson.Safe.Util in
  let ts = match member "ts" j with
    | `Int n -> Int64.of_int n
    | `Intlit s -> Int64.of_string s
    | `String s -> Int64.of_string s
    | _ -> invalid_arg "Candle.ts"
  in
  let d k = Decimal_json.t_of_yojson (member k j) in
  Candle.make ~ts
    ~open_:(d "open") ~high:(d "high") ~low:(d "low")
    ~close:(d "close") ~volume:(d "volume")

(** Broker-agnostic ISO-8601 → unix epoch seconds (UTC "Z" suffix). *)
let parse_iso8601 (s : string) : int64 =
  try
    Scanf.sscanf s "%d-%d-%dT%d:%d:%d"
      (fun y mo d h mi se ->
         let y = if mo <= 2 then y - 1 else y in
         let era = (if y >= 0 then y else y - 399) / 400 in
         let yoe = y - era * 400 in
         let m' = if mo > 2 then mo - 3 else mo + 9 in
         let doy = (153 * m' + 2) / 5 + d - 1 in
         let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy in
         let days = era * 146097 + doe - 719468 in
         Int64.(add (mul (of_int days) 86400L)
                  (of_int (h * 3600 + mi * 60 + se))))
  with _ ->
    try Int64.of_string s with _ -> 0L

(** Flexible per-bar decoder tolerant of common broker response
    variations. Each field name has several candidates:
      - timestamp: "timestamp", "time", "t", "ts"
      - OHLC:      plain or short ("open", "o"), decimal or wrapper
      - volume:    "volume", "vol", "v", "total_volume"
    Unknown fields are ignored; required ones fall through to 0 rather
    than raise, so a partial response still yields a usable candle. *)
let of_yojson_flex (j : Yojson.Safe.t) : Candle.t =
  let open Yojson.Safe.Util in
  let find names =
    List.fold_left (fun acc k ->
      match acc with
      | `Null -> member k j
      | v -> v) `Null names
  in
  let ts = match find ["timestamp"; "time"; "t"; "ts"] with
    | `String s -> parse_iso8601 s
    | `Int n -> Int64.of_int n
    | `Intlit s -> Int64.of_string s
    | _ -> 0L
  in
  let dec names =
    try Decimal_json.of_yojson_flex (find names)
    with _ -> Decimal.zero
  in
  Candle.make ~ts
    ~open_:(dec ["open"; "o"])
    ~high:(dec ["high"; "h"])
    ~low:(dec ["low"; "l"])
    ~close:(dec ["close"; "c"])
    ~volume:(dec ["volume"; "vol"; "v"; "total_volume"])
