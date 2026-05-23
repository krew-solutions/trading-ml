open Core

type validation_error = Invalid_symbol of string | Invalid_timeframe of string

let validation_error_to_string = function
  | Invalid_symbol s -> Printf.sprintf "invalid symbol: %S" s
  | Invalid_timeframe s -> Printf.sprintf "invalid timeframe: %S" s

type validated_watch_bars_command = { instrument : Instrument.t; timeframe : Timeframe.t }

type handle_error = Validation of validation_error

let parse_instrument raw : (Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Instrument.of_qualified raw)
  with Invalid_argument _ | Failure _ -> Rop.fail (Invalid_symbol raw)

let parse_timeframe raw : (Timeframe.t, validation_error) Rop.t =
  try Rop.succeed (Timeframe.of_string raw) with _ -> Rop.fail (Invalid_timeframe raw)

let validate (cmd : Watch_bars_command.t) :
    (validated_watch_bars_command, validation_error) Rop.t =
  let open Rop in
  let+ instrument = parse_instrument cmd.symbol
  and+ timeframe = parse_timeframe cmd.timeframe in
  { instrument; timeframe }

let watch ~(broker : Broker.client) (v : validated_watch_bars_command) : unit =
  Broker.subscribe broker
    (Subscribe_bars { instrument = v.instrument; timeframe = v.timeframe })

let handle ~(broker : Broker.client) (cmd : Watch_bars_command.t) :
    (unit, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v ->
      watch ~broker v;
      Rop.succeed ()
