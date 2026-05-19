module Pm = Portfolio_management
module SBA = Subscribe_book_to_alpha_command

type validation_error =
  | Invalid_alpha_source_id of string
  | Invalid_instrument of string
  | Invalid_book_id of string

let validation_error_to_string = function
  | Invalid_alpha_source_id s -> Printf.sprintf "invalid alpha_source_id: %S" s
  | Invalid_instrument s -> Printf.sprintf "invalid instrument: %S" s
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s

type handle_error = Validation of validation_error

let handle_error_to_string = function
  | Validation v -> validation_error_to_string v

let parse_alpha_source_id raw : (Pm.Common.Alpha_source_id.t, validation_error) Rop.t =
  try Rop.succeed (Pm.Common.Alpha_source_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_alpha_source_id raw)

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_instrument raw)

let parse_book_id raw : (Pm.Common.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Pm.Common.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let handle ~persist_subscription (cmd : SBA.t) : (unit, handle_error) Rop.t =
  let open Rop in
  let parsed =
    let+ alpha_source_id = parse_alpha_source_id cmd.alpha_source_id
    and+ instrument = parse_instrument cmd.instrument
    and+ book_id = parse_book_id cmd.book_id in
    (alpha_source_id, instrument, book_id)
  in
  match parsed with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok (alpha_source_id, instrument, book_id) ->
      let sub =
        Pm.Common.Alpha_subscription.make ~alpha_source_id ~instrument ~book_id
      in
      persist_subscription sub;
      Rop.succeed ()
