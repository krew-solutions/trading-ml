open Core
module Footprint = Order_flow.Footprint
module Print = Order_flow.Footprint.Values.Print
module Aggressor = Order_flow.Footprint.Values.Aggressor
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary
module Bar_opened = Order_flow.Footprint.Events.Bar_opened
module Footprint_completed = Order_flow.Footprint.Events.Footprint_completed

type validation_error =
  | Invalid_symbol of string
  | Invalid_price_format of string
  | Invalid_size_format of string
  | Non_positive_size of string
  | Invalid_aggressor of string

let validation_error_to_string = function
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_price_format s -> Printf.sprintf "invalid price format: %S" s
  | Invalid_size_format s -> Printf.sprintf "invalid size format: %S" s
  | Non_positive_size s -> Printf.sprintf "size must be > 0, got %s" s
  | Invalid_aggressor s ->
      Printf.sprintf "invalid aggressor: %S (expected BUY | SELL | UNSPECIFIED)" s

type validated_ingest_print_command = { instrument : Instrument.t; print : Print.t }

type handle_error = Validation of validation_error

(* What ingesting one print did to the per-instrument forming bar.
   [Rejected_late] is not an error — the command was well-formed; the
   print simply belongs to an already-passed bucket and a sealed bar is
   never reopened (ADR 0032). The workflow logs it; the pipeline does
   not fail. *)
type outcome =
  | Opened of Bar_opened.t
  | Absorbed
  | Rolled of Footprint_completed.t * Bar_opened.t
  | Rejected_late

let parse_symbol raw : (Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_symbol raw)

let parse_price raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (Invalid_price_format raw)

let parse_size raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (Invalid_size_format raw)
  | Some d ->
      if Decimal.is_positive d then Rop.succeed d else Rop.fail (Non_positive_size raw)

let parse_aggressor raw : (Aggressor.t, validation_error) Rop.t =
  try Rop.succeed (Aggressor.of_string (String.uppercase_ascii raw))
  with Invalid_argument _ -> Rop.fail (Invalid_aggressor raw)

let validate (cmd : Ingest_print_command.t) :
    (validated_ingest_print_command, validation_error) Rop.t =
  let open Rop in
  let+ instrument = parse_symbol cmd.symbol
  and+ price = parse_price cmd.price
  and+ size = parse_size cmd.size
  and+ aggressor = parse_aggressor cmd.aggressor in
  (* [ts] uses Iso8601.parse, which is total (falls back rather than
     raising) — no validation branch. [size] is already positive, so
     [Print.make] cannot raise here. *)
  let ts = Datetime.Iso8601.parse cmd.ts in
  { instrument; print = Print.make ~price ~size ~ts ~aggressor }

let handle
    ~(boundary : Bar_boundary.t)
    ~(get_bar : Instrument.t -> Footprint.t option)
    ~(put_bar : Instrument.t -> Footprint.t -> unit)
    (cmd : Ingest_print_command.t) : (outcome, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok { instrument; print } -> (
      match get_bar instrument with
      | None ->
          let bar, opened = Footprint.open_ ~instrument ~boundary ~first:print in
          put_bar instrument bar;
          Rop.succeed (Opened opened)
      | Some bar -> (
          match Footprint.classify bar print with
          | Footprint.In_bar ->
              put_bar instrument (Footprint.absorb bar print);
              Rop.succeed Absorbed
          | Footprint.Opens_later ->
              let _sealed, completed = Footprint.seal bar in
              let bar', opened = Footprint.open_ ~instrument ~boundary ~first:print in
              put_bar instrument bar';
              Rop.succeed (Rolled (completed, opened))
          | Footprint.Late -> Rop.succeed Rejected_late))
