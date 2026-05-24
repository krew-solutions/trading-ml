open Core
module Pm = Portfolio_management
module DPKM = Define_pair_kalman_mr_command

type validation_error =
  | Invalid_book_id of string
  | Invalid_instrument of { field : string; value : string }
  | Invalid_pair of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_z_score of { field : string; value : string }
  | Invalid_discount of string
  | Invalid_v_observation_noise of string
  | Invalid_burn_in of int
  | Invalid_prior_variance of string
  | Invalid_prior_beta of string
  | Invalid_kalman_config of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_instrument { field; value } ->
      Printf.sprintf "invalid instrument for %s: %S" field value
  | Invalid_pair s -> Printf.sprintf "invalid pair: %s" s
  | Invalid_decimal { field; value } ->
      Printf.sprintf "invalid decimal for %s: %S" field value
  | Invalid_z_score { field; value } ->
      Printf.sprintf "invalid z_score for %s: %S" field value
  | Invalid_discount s -> Printf.sprintf "invalid discount (must be in (0, 1)): %s" s
  | Invalid_v_observation_noise s ->
      Printf.sprintf "invalid v observation noise (must be > 0): %s" s
  | Invalid_burn_in n -> Printf.sprintf "invalid burn_in (must be >= 0): %d" n
  | Invalid_prior_variance s ->
      Printf.sprintf "invalid prior_variance (must be > 0): %s" s
  | Invalid_prior_beta s -> Printf.sprintf "invalid prior_beta (must be > 0): %s" s
  | Invalid_kalman_config s -> Printf.sprintf "invalid Kalman_dlm_config: %s" s

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

let handle ~persist_pair_kalman_mr_state (cmd : DPKM.t) : (unit, handle_error) Rop.t =
  let open Rop in
  let parsed_fields =
    let+ book_id = parse_book_id cmd.book_id
    and+ a = parse_instrument ~field:"a" cmd.a
    and+ b = parse_instrument ~field:"b" cmd.b
    and+ discount = parse_decimal ~field:"discount" cmd.discount
    and+ v = parse_decimal ~field:"v" cmd.v
    and+ z_entry = parse_z_score ~field:"z_entry" cmd.z_entry
    and+ z_exit = parse_z_score ~field:"z_exit" cmd.z_exit
    and+ prior_alpha = parse_decimal ~field:"prior_alpha" cmd.prior_alpha
    and+ prior_beta = parse_decimal ~field:"prior_beta" cmd.prior_beta
    and+ prior_variance = parse_decimal ~field:"prior_variance" cmd.prior_variance in
    (book_id, a, b, discount, v, z_entry, z_exit, prior_alpha, prior_beta, prior_variance)
  in
  match parsed_fields with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok
      ( book_id,
        a,
        b,
        discount,
        v,
        z_entry,
        z_exit,
        prior_alpha,
        prior_beta,
        prior_variance ) -> (
      (* Surface domain-invariant violations from each VO with
         their own validation tags before the Kalman_dlm_config
         smart constructor would raise a more generic
         Invalid_kalman_config. *)
      let pair_or_err =
        try Rop.succeed (Pm.Common.Pair.make ~a ~b)
        with Invalid_argument msg -> Rop.fail (Invalid_pair msg)
      in
      let discount_or_err =
        if
          (not (Decimal.is_positive discount))
          || Decimal.compare discount Decimal.one >= 0
        then Rop.fail (Invalid_discount (Decimal.to_string discount))
        else Rop.succeed discount
      in
      let v_or_err =
        if not (Decimal.is_positive v) then
          Rop.fail (Invalid_v_observation_noise (Decimal.to_string v))
        else Rop.succeed v
      in
      let burn_in_or_err =
        if cmd.burn_in < 0 then Rop.fail (Invalid_burn_in cmd.burn_in)
        else Rop.succeed cmd.burn_in
      in
      let prior_variance_or_err =
        if not (Decimal.is_positive prior_variance) then
          Rop.fail (Invalid_prior_variance (Decimal.to_string prior_variance))
        else Rop.succeed prior_variance
      in
      let prior_beta_or_err =
        if not (Decimal.is_positive prior_beta) then
          Rop.fail (Invalid_prior_beta (Decimal.to_string prior_beta))
        else Rop.succeed prior_beta
      in
      let built =
        let+ pair = pair_or_err
        and+ discount = discount_or_err
        and+ v = v_or_err
        and+ burn_in = burn_in_or_err
        and+ prior_variance = prior_variance_or_err
        and+ prior_beta = prior_beta_or_err in
        (pair, discount, v, burn_in, prior_variance, prior_beta)
      in
      match built with
      | Error errs -> Error (List.map (fun e -> Validation e) errs)
      | Ok (pair, discount, v, burn_in, prior_variance, prior_beta) -> (
          try
            let cfg =
              Pm.Pair_kalman_mean_reversion.Values.Kalman_dlm_config.make ~book_id ~pair
                ~discount ~v ~z_entry ~z_exit ~burn_in ~prior_alpha ~prior_beta
                ~prior_variance
            in
            let state = Pm.Pair_kalman_mean_reversion.init cfg in
            persist_pair_kalman_mr_state ~book_id ~pair ~state;
            Rop.succeed ()
          with Invalid_argument msg -> Error [ Validation (Invalid_kalman_config msg) ]))
