(** Finam wire DTOs: decode JSON payloads into domain types.
    This module isolates wire-format concerns from the rest of the system,
    so a switch from REST → gRPC only touches this file. *)

open Core

(** A raw-sample sink that the caller can set from outside to capture
    unexpected response shapes for debugging. When non-[None], the
    candle decoder prints the first raw bar it sees to stderr (once
    per process) so a single failing request makes the real payload
    visible without guessing. *)
let debug_sample_logged = ref false
let debug_log_sample ?(label = "bar") (j : Yojson.Safe.t) : unit =
  if not !debug_sample_logged then begin
    debug_sample_logged := true;
    Printf.eprintf "[finam dto] sample %s: %s\n%!"
      label (Yojson.Safe.to_string j)
  end

(** Decode a decimal-ish field tolerantly.
    Accepts all of:
      - "1.23"
      - 123
      - 1.23
      - { "value": "1.23" }  (gRPC Decimal wrapper)
      - { "value": "123", "scale": 2 }  (proto Money-style: val / 10^scale)
      - absent / null → 0 (callers decide if that's a problem)

    When a lookup under [names] hits a truly unknown shape, raises
    [Invalid_argument] with the field name; used for required fields. *)
let rec decimal_of_json : Yojson.Safe.t -> Decimal.t = function
  | `String s -> Decimal.of_string s
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s -> Decimal.of_string s
  | `Assoc fields as j ->
    (match List.assoc_opt "value" fields with
     | Some v ->
       let base = decimal_of_json v in
       (* Optional proto-style { value, scale }: divide by 10^scale. *)
       (match List.assoc_opt "scale" fields with
        | Some (`Int 0) | None -> base
        | Some (`Int k) when k > 0 ->
          let rec pow10 n = if n <= 0 then 1 else 10 * pow10 (n - 1) in
          Decimal.div base (Decimal.of_int (pow10 k))
        | _ -> base)
     | None -> invalid_arg ("Finam DTO: decimal object without value: "
                            ^ Yojson.Safe.to_string j))
  | `Null -> Decimal.zero
  | j -> invalid_arg ("Finam DTO: not a decimal: " ^ Yojson.Safe.to_string j)

(** Tries a sequence of candidate field names, returning the first one
    that's present and non-null. Makes the decoder tolerant of the
    gRPC→REST bridge relabeling fields (volume vs vol vs v, etc.). *)
let decimal_field_any ?(required = true) j candidates =
  let rec loop = function
    | [] ->
      if required then
        invalid_arg ("Finam DTO: missing decimal field "
                     ^ String.concat "/" candidates)
      else Decimal.zero
    | k :: rest ->
      match Yojson.Safe.Util.member k j with
      | `Null -> loop rest
      | v ->
        try decimal_of_json v
        with _ -> loop rest
  in
  loop candidates

let decimal_field k j = decimal_field_any j [k]

(** Minimal ISO-8601 → epoch seconds (UTC). Finam returns Z-suffixed UTC. *)
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

let candle_of_json j : Candle.t =
  (* On the first decode, log the raw shape so we can see what the
     server actually sends without adding an ad-hoc debug flag. *)
  debug_log_sample ~label:"bar" j;
  let ts =
    match Yojson.Safe.Util.member "timestamp" j with
    | `String s -> parse_iso8601 s
    | `Int n -> Int64.of_int n
    | `Intlit s -> Int64.of_string s
    | `Null ->
      (* Alternative common names: 'time', 't'. *)
      (match Yojson.Safe.Util.member "time" j with
       | `String s -> parse_iso8601 s
       | `Int n -> Int64.of_int n
       | _ -> 0L)
    | _ -> 0L
  in
  (* Per-field candidate lists: first match wins. Volume is the one that
     notoriously varies between gRPC transcoders. *)
  let open_  = decimal_field_any j ["open"; "o"] in
  let high   = decimal_field_any j ["high"; "h"] in
  let low    = decimal_field_any j ["low";  "l"] in
  let close  = decimal_field_any j ["close"; "c"] in
  let volume = decimal_field_any ~required:false j
    ["volume"; "vol"; "v"; "total_volume"; "trading_volume"] in
  Candle.make ~ts ~open_ ~high ~low ~close ~volume

let candles_of_json j : Candle.t list =
  let arr = match Yojson.Safe.Util.member "bars" j with
    | `List l -> l
    | _ ->
      match Yojson.Safe.Util.member "candles" j with
      | `List l -> l
      | `Null ->
        (* Some gRPC bridges wrap the payload under "result": { "bars": [...] }. *)
        (match Yojson.Safe.Util.member "result" j with
         | `Assoc _ as inner ->
           (match Yojson.Safe.Util.member "bars" inner with
            | `List l -> l | _ -> [])
         | _ -> [])
      | _ -> []
  in
  List.map candle_of_json arr
