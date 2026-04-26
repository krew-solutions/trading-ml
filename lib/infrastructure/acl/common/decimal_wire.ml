open Core

let yojson_of_t x : Yojson.Safe.t = `String (Decimal.to_string x)

let yojson_of_t_wrapped x : Yojson.Safe.t =
  `Assoc [ ("value", `String (Decimal.to_string x)) ]

let t_of_yojson : Yojson.Safe.t -> Decimal.t = function
  | `String s -> Decimal.of_string s
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s -> Decimal.of_string s
  | j -> invalid_arg ("Decimal_wire.t_of_yojson: " ^ Yojson.Safe.to_string j)

let rec of_yojson_flex : Yojson.Safe.t -> Decimal.t = function
  | `String s -> Decimal.of_string s
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s -> Decimal.of_string s
  | `Assoc fields as j -> (
      match List.assoc_opt "value" fields with
      | Some v -> (
          let base = of_yojson_flex v in
          match List.assoc_opt "scale" fields with
          | Some (`Int 0) | None -> base
          | Some (`Int k) when k > 0 ->
              let rec pow10 n = if n <= 0 then 1 else 10 * pow10 (n - 1) in
              Decimal.div base (Decimal.of_int (pow10 k))
          | _ -> base)
      | None ->
          invalid_arg
            ("Decimal_wire.of_yojson_flex: no value in " ^ Yojson.Safe.to_string j))
  | `Null -> Decimal.zero
  | j ->
      invalid_arg
        ("Decimal_wire.of_yojson_flex: not a decimal: " ^ Yojson.Safe.to_string j)
