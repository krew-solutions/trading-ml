open Core
module Bar_boundary = Order_flow.Footprint.Values.Bar_boundary

type validation_error = Invalid_symbol of string | Invalid_boundary of string

let validation_error_to_string = function
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_boundary s -> Printf.sprintf "invalid boundary token: %S" s

type validated_unwatch_footprints_command = {
  instrument : Instrument.t;
  boundary : Bar_boundary.t;
}

type handle_error = Validation of validation_error

let parse_instrument raw : (Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Instrument.of_qualified raw)
  with Invalid_argument _ | Failure _ -> Rop.fail (Invalid_symbol raw)

let parse_boundary raw : (Bar_boundary.t, validation_error) Rop.t =
  try Rop.succeed (Bar_boundary.of_token raw)
  with Invalid_argument _ -> Rop.fail (Invalid_boundary raw)

let validate (cmd : Unwatch_footprints_command.t) :
    (validated_unwatch_footprints_command, validation_error) Rop.t =
  let open Rop in
  let+ instrument = parse_instrument cmd.symbol
  and+ boundary = parse_boundary cmd.boundary in
  { instrument; boundary }

let handle
    ~(unwatch : instrument:Instrument.t -> boundary:Bar_boundary.t -> unit)
    (cmd : Unwatch_footprints_command.t) : (unit, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok { instrument; boundary } ->
      unwatch ~instrument ~boundary;
      Rop.succeed ()
