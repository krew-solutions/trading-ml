(** Finam wire DTOs: decode JSON payloads into domain types.
    This module isolates wire-format concerns from the rest of the system,
    so a switch from REST → gRPC only touches this file. *)

open Core

module Order = Order
(** Per-record DTO sub-modules. Collapse-rule [dto/dto.ml] does
    not pick up siblings automatically — they have to be listed
    here, same convention as {!Ws}. *)

module Trade = Trade
module Wire = Wire

include Wire
(** Convenience re-export of {!Wire} so callers reading
    [Dto.decimal_of_json] / [Dto.finam_side_of_wire] continue to
    work without the [Wire.] prefix. *)

(** A raw-sample sink that the caller can set from outside to capture
    unexpected response shapes for debugging. When non-[None], the
    candle decoder prints the first raw bar it sees to stderr (once
    per process) so a single failing request makes the real payload
    visible without guessing. *)
let debug_sample_logged = ref false

let debug_log_sample ?(label = "bar") (j : Yojson.Safe.t) : unit =
  if not !debug_sample_logged then begin
    debug_sample_logged := true;
    Log.debug "[finam dto] sample %s: %s" label (Yojson.Safe.to_string j)
  end

let candle_of_json j : Candle.t =
  (* On the first decode, log the raw shape so we can see what the
     server actually sends without adding an ad-hoc debug flag. *)
  debug_log_sample ~label:"bar" j;
  let ts =
    match Yojson.Safe.Util.member "timestamp" j with
    | `String s -> Datetime.Iso8601.parse s
    | `Int n -> Int64.of_int n
    | `Intlit s -> Int64.of_string s
    | `Null -> (
        (* Alternative common names: 'time', 't'. *)
        match Yojson.Safe.Util.member "time" j with
        | `String s -> Datetime.Iso8601.parse s
        | `Int n -> Int64.of_int n
        | _ -> 0L)
    | _ -> 0L
  in
  (* Per-field candidate lists: first match wins. Volume is the one that
     notoriously varies between gRPC transcoders. *)
  let open_ = decimal_field_any j [ "open"; "o" ] in
  let high = decimal_field_any j [ "high"; "h" ] in
  let low = decimal_field_any j [ "low"; "l" ] in
  let close = decimal_field_any j [ "close"; "c" ] in
  let volume =
    decimal_field_any ~required:false j
      [ "volume"; "vol"; "v"; "total_volume"; "trading_volume" ]
  in
  Candle.make ~ts ~open_ ~high ~low ~close ~volume

(** Decode Finam's [GetAssetResponse] (proto field set: board, id,
    ticker, mic, isin, type, name, decimals, min_step, lot_size,
    quote_currency, asset_details).

    We keep only what {!Instrument} needs: ticker, mic, optional
    isin, optional board. The rest (decimals, lot_size, …) is
    instrument *metadata* — out of scope for identity.

    Defensive: ISIN is optional in the wire payload (futures often
    don't have one), and we silently drop invalid ISINs (length /
    checksum) instead of failing the whole decode — the instrument is
    still usable without it. *)
let instrument_of_asset_json (j : Yojson.Safe.t) : Instrument.t =
  let open Yojson.Safe.Util in
  let str_opt k =
    match member k j with
    | `String "" | `Null -> None
    | `String s -> Some s
    | _ -> None
  in
  let req_str k =
    match str_opt k with
    | Some s -> s
    | None -> invalid_arg ("Finam DTO asset: missing string field " ^ k)
  in
  let ticker = Ticker.of_string (req_str "ticker") in
  let venue = Mic.of_string (req_str "mic") in
  let isin =
    match str_opt "isin" with
    | None -> None
    | Some s -> ( try Some (Isin.of_string s) with Invalid_argument _ -> None)
  in
  let board =
    match str_opt "board" with
    | None -> None
    | Some s -> ( try Some (Board.of_string s) with Invalid_argument _ -> None)
  in
  Instrument.make ~ticker ~venue ?isin ?board ()

let candles_of_json j : Candle.t list =
  let arr =
    match Yojson.Safe.Util.member "bars" j with
    | `List l -> l
    | _ -> (
        match Yojson.Safe.Util.member "candles" j with
        | `List l -> l
        | `Null -> (
            (* Some gRPC bridges wrap the payload under "result": { "bars": [...] }. *)
            match Yojson.Safe.Util.member "result" j with
            | `Assoc _ as inner -> (
                match Yojson.Safe.Util.member "bars" inner with
                | `List l -> l
                | _ -> [])
            | _ -> [])
        | _ -> [])
  in
  List.map candle_of_json arr
