(** Separate JSON encoding so [Decimal.mli] stays free of external-module
    references and remains Gospel-checkable. *)

let yojson_of_t x : Yojson.Safe.t = `String (Decimal.to_string x)

let t_of_yojson : Yojson.Safe.t -> Decimal.t = function
  | `String s -> Decimal.of_string s
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s -> Decimal.of_string s
  | j -> invalid_arg ("Decimal.t_of_yojson: " ^ Yojson.Safe.to_string j)

(** Defensive decoder tolerant of broker-specific wrappings.
    Accepts plain strings/numbers, gRPC-style `{"value": "…"}` objects,
    and optional proto-style `{"value": "…", "scale": n}` where the
    numeric is divided by 10^scale. Used by any broker DTO that
    ingests decimal fields from the wire. *)
let rec of_yojson_flex : Yojson.Safe.t -> Decimal.t = function
  | `String s -> Decimal.of_string s
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s -> Decimal.of_string s
  | `Assoc fields as j ->
    (match List.assoc_opt "value" fields with
     | Some v ->
       let base = of_yojson_flex v in
       (match List.assoc_opt "scale" fields with
        | Some (`Int 0) | None -> base
        | Some (`Int k) when k > 0 ->
          let rec pow10 n = if n <= 0 then 1 else 10 * pow10 (n - 1) in
          Decimal.div base (Decimal.of_int (pow10 k))
        | _ -> base)
     | None -> invalid_arg ("Decimal_json.flex: no value in "
                            ^ Yojson.Safe.to_string j))
  | `Null -> Decimal.zero
  | j -> invalid_arg ("Decimal_json.flex: not a decimal: "
                      ^ Yojson.Safe.to_string j)
