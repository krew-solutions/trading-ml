module Alpha_view = Portfolio_management.Alpha_view
module Common = Portfolio_management.Common

type validation_error =
  | Invalid_alpha_source_id of string
  | Invalid_instrument of string
  | Invalid_direction of string
  | Invalid_strength of float
  | Invalid_price_format of string
  | Negative_price of string
  | Invalid_occurred_at of string

let validation_error_to_string = function
  | Invalid_alpha_source_id s -> Printf.sprintf "invalid alpha_source_id: %S" s
  | Invalid_instrument s -> Printf.sprintf "invalid instrument: %S" s
  | Invalid_direction s ->
      Printf.sprintf "invalid direction: %S (expected UP|DOWN|FLAT)" s
  | Invalid_strength f -> Printf.sprintf "invalid strength: %g (NaN or non-finite)" f
  | Invalid_price_format s -> Printf.sprintf "invalid price format: %S" s
  | Negative_price s -> Printf.sprintf "price must be >= 0, got %s" s
  | Invalid_occurred_at s -> Printf.sprintf "invalid occurred_at (ISO-8601): %S" s

type validated_define_alpha_view_command = {
  alpha_source_id : Common.Alpha_source_id.t;
  instrument : Core.Instrument.t;
  direction : Common.Direction.t;
  strength : float;
  price : Decimal.t;
  occurred_at : int64;
}

type handle_error = Validation of validation_error

let parse_alpha_source_id raw : (Common.Alpha_source_id.t, validation_error) Rop.t =
  try Rop.succeed (Common.Alpha_source_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_alpha_source_id raw)

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_instrument raw)

let parse_direction raw : (Common.Direction.t, validation_error) Rop.t =
  try Rop.succeed (Common.Direction.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_direction raw)

let parse_strength f : (float, validation_error) Rop.t =
  if Float.is_finite f then Rop.succeed f else Rop.fail (Invalid_strength f)

let parse_price raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | None -> Rop.fail (Invalid_price_format raw)
  | Some d ->
      if Decimal.is_negative d then Rop.fail (Negative_price raw) else Rop.succeed d

let parse_occurred_at raw : (int64, validation_error) Rop.t =
  let parsed = Datetime.Iso8601.parse raw in
  if Int64.equal parsed 0L then Rop.fail (Invalid_occurred_at raw) else Rop.succeed parsed

let validate (cmd : Define_alpha_view_command.t) :
    (validated_define_alpha_view_command, validation_error) Rop.t =
  let open Rop in
  let+ alpha_source_id = parse_alpha_source_id cmd.alpha_source_id
  and+ instrument = parse_instrument cmd.instrument
  and+ direction = parse_direction cmd.direction
  and+ strength = parse_strength cmd.strength
  and+ price = parse_price cmd.price
  and+ occurred_at = parse_occurred_at cmd.occurred_at in
  { alpha_source_id; instrument; direction; strength; price; occurred_at }

let handle
    ~(alpha_view_for :
       alpha_source_id:Common.Alpha_source_id.t ->
       instrument:Core.Instrument.t ->
       Alpha_view.t ref)
    (cmd : Define_alpha_view_command.t) :
    (Alpha_view.Events.Direction_changed.t option, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v ->
      let view_ref =
        alpha_view_for ~alpha_source_id:v.alpha_source_id ~instrument:v.instrument
      in
      let view', event_opt =
        Alpha_view.define !view_ref ~direction:v.direction ~strength:v.strength
          ~price:v.price ~occurred_at:v.occurred_at
      in
      view_ref := view';
      Rop.succeed event_opt
