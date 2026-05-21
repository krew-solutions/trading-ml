open Core
module Pm = Portfolio_management
module DPM = Define_pair_mr_command

type validation_error =
  | Invalid_book_id of string
  | Invalid_instrument of { field : string; value : string }
  | Invalid_pair of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_hedge_ratio of string
  | Invalid_z_score of { field : string; value : string }
  | Invalid_config of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_instrument { field; value } ->
      Printf.sprintf "invalid instrument for %s: %S" field value
  | Invalid_pair s -> Printf.sprintf "invalid pair: %s" s
  | Invalid_decimal { field; value } ->
      Printf.sprintf "invalid decimal for %s: %S" field value
  | Invalid_hedge_ratio s -> Printf.sprintf "invalid hedge_ratio: %s" s
  | Invalid_z_score { field; value } ->
      Printf.sprintf "invalid z_score for %s: %S" field value
  | Invalid_config s -> Printf.sprintf "invalid Pair_mr_config: %s" s

type handle_error = Validation of validation_error

let handle_error_to_string = function
  | Validation v -> validation_error_to_string v

let parse_book_id raw : (Pm.Common.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Pm.Common.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_instrument ~field raw : (Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_instrument { field; value = raw })

let parse_decimal ~field raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (Invalid_decimal { field; value = raw })

let parse_z_score ~field raw : (Pm.Common.Z_score.t, validation_error) Rop.t =
  let parsed =
    try
      let d = Decimal.of_string raw in
      Some (Pm.Common.Z_score.of_float (Decimal.to_float d))
    with Invalid_argument _ -> None
  in
  match parsed with
  | Some z -> Rop.succeed z
  | None -> Rop.fail (Invalid_z_score { field; value = raw })

let handle ~persist_pair_mr_state (cmd : DPM.t) : (unit, handle_error) Rop.t =
  let open Rop in
  let parsed_fields =
    let+ book_id = parse_book_id cmd.book_id
    and+ a = parse_instrument ~field:"a" cmd.a
    and+ b = parse_instrument ~field:"b" cmd.b
    and+ hedge_decimal = parse_decimal ~field:"hedge_ratio" cmd.hedge_ratio
    and+ z_entry = parse_z_score ~field:"z_entry" cmd.z_entry
    and+ z_exit = parse_z_score ~field:"z_exit" cmd.z_exit in
    (book_id, a, b, hedge_decimal, z_entry, z_exit)
  in
  match parsed_fields with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok (book_id, a, b, hedge_decimal, z_entry, z_exit) -> (
      let built =
        let open Rop in
        let+ pair =
          try Rop.succeed (Pm.Common.Pair.make ~a ~b)
          with Invalid_argument msg -> Rop.fail (Invalid_pair msg)
        and+ hedge_ratio =
          try Rop.succeed (Pm.Common.Hedge_ratio.of_decimal hedge_decimal)
          with Invalid_argument msg -> Rop.fail (Invalid_hedge_ratio msg)
        in
        (pair, hedge_ratio)
      in
      match built with
      | Error errs -> Error (List.map (fun e -> Validation e) errs)
      | Ok (pair, hedge_ratio) -> (
          try
            let cfg =
              Pm.Pair_mean_reversion.Values.Pair_mr_config.make ~book_id ~pair
                ~hedge_ratio ~window:cmd.window ~z_entry ~z_exit
            in
            let state = Pm.Pair_mean_reversion.init cfg in
            persist_pair_mr_state ~book_id ~pair ~state;
            Rop.succeed ()
          with Invalid_argument msg -> Error [ Validation (Invalid_config msg) ]))
