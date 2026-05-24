open Core
module Pm = Portfolio_management
module CR = Configure_risk_command

type validation_error =
  | Invalid_book_id of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_fraction_range of string
  | Invalid_limits of string
  | Invalid_alpha_source_id of string
  | Invalid_instrument of { field : string; value : string }
  | Invalid_pair of string
  | Invalid_target_vol of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_decimal { field; value } ->
      Printf.sprintf "invalid decimal for %s: %S" field value
  | Invalid_fraction_range s -> Printf.sprintf "risk_budget_fraction out of [0, 1]: %s" s
  | Invalid_limits s -> Printf.sprintf "invalid Risk_limits: %s" s
  | Invalid_alpha_source_id s -> Printf.sprintf "invalid alpha_source_id: %S" s
  | Invalid_instrument { field; value } ->
      Printf.sprintf "invalid instrument for %s: %S" field value
  | Invalid_pair s -> Printf.sprintf "invalid pair: %s" s
  | Invalid_target_vol s -> Printf.sprintf "target_annual_vol must be >= 0 (got %s)" s

type handle_error = Validation of validation_error

let handle_error_to_string = function
  | Validation v -> validation_error_to_string v

let parse_book_id raw : (Pm.Common.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Pm.Common.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_decimal ~field raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (Invalid_decimal { field; value = raw })

let parse_alpha_source_id raw : (Pm.Common.Alpha_source_id.t, validation_error) Rop.t =
  try Rop.succeed (Pm.Common.Alpha_source_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_alpha_source_id raw)

let parse_instrument ~field raw : (Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_instrument { field; value = raw })

let parse_construction_source (src : CR.construction_source) :
    (Pm.Common.Source.t, validation_error) Rop.t =
  match src with
  | `Alpha_view payload ->
      let open Rop in
      let+ id = parse_alpha_source_id payload.alpha_source_id in
      Pm.Common.Source.Alpha_view id
  | `Pair_mean_reversion payload -> (
      let open Rop in
      let parsed =
        let+ a = parse_instrument ~field:"a" payload.a
        and+ b = parse_instrument ~field:"b" payload.b in
        (a, b)
      in
      match parsed with
      | Error _ as e -> e
      | Ok (a, b) -> (
          try
            Rop.succeed (Pm.Common.Source.Pair_mean_reversion (Pm.Common.Pair.make ~a ~b))
          with Invalid_argument msg -> Rop.fail (Invalid_pair msg)))
  | `Pair_kalman_mean_reversion payload -> (
      let open Rop in
      let parsed =
        let+ a = parse_instrument ~field:"a" payload.a
        and+ b = parse_instrument ~field:"b" payload.b in
        (a, b)
      in
      match parsed with
      | Error _ as e -> e
      | Ok (a, b) -> (
          try
            Rop.succeed
              (Pm.Common.Source.Pair_kalman_mean_reversion (Pm.Common.Pair.make ~a ~b))
          with Invalid_argument msg -> Rop.fail (Invalid_pair msg)))

let parse_sizing_policy (sp : CR.sizing_policy) :
    (Pm.Common.Sizing_policy_choice.t, validation_error) Rop.t =
  match sp with
  | `Equity_proportional -> Rop.succeed Pm.Common.Sizing_policy_choice.Equity_proportional
  | `Volatility_target { CR.target_annual_vol } -> (
      match try Some (Decimal.of_string target_annual_vol) with _ -> None with
      | None ->
          Rop.fail
            (Invalid_decimal { field = "target_annual_vol"; value = target_annual_vol })
      | Some d ->
          if Decimal.is_negative d then Rop.fail (Invalid_target_vol target_annual_vol)
          else
            Rop.succeed
              (Pm.Common.Sizing_policy_choice.Volatility_target { target_annual_vol = d })
      )

let in_unit_interval d =
  (not (Decimal.is_negative d)) && Decimal.compare d Decimal.one <= 0

let build_risk_config
    ~(book_id : Pm.Common.Book_id.t)
    ~(risk_budget_fraction : Decimal.t)
    ~(max_per_instrument_notional : Decimal.t)
    ~(max_gross_exposure : Decimal.t)
    ~(construction_source : Pm.Common.Source.t)
    ~(sizing_policy : Pm.Common.Sizing_policy_choice.t) :
    (Pm.Risk_config.t, validation_error) Rop.t =
  if not (in_unit_interval risk_budget_fraction) then
    Rop.fail (Invalid_fraction_range (Decimal.to_string risk_budget_fraction))
  else
    try
      let limits =
        Pm.Risk.Values.Risk_limits.make ~max_per_instrument_notional ~max_gross_exposure
      in
      Rop.succeed
        (Pm.Risk_config.make ~book_id ~risk_budget_fraction ~limits ~construction_source
           ~sizing_policy)
    with Invalid_argument msg -> Rop.fail (Invalid_limits msg)

let handle ~persist_risk_config (cmd : CR.t) : (unit, handle_error) Rop.t =
  let open Rop in
  let validated =
    let+ book_id = parse_book_id cmd.book_id
    and+ risk_budget_fraction =
      parse_decimal ~field:"risk_budget_fraction" cmd.risk_budget_fraction
    and+ max_per_instrument_notional =
      parse_decimal ~field:"max_per_instrument_notional" cmd.max_per_instrument_notional
    and+ max_gross_exposure =
      parse_decimal ~field:"max_gross_exposure" cmd.max_gross_exposure
    and+ construction_source = parse_construction_source cmd.construction_source
    and+ sizing_policy = parse_sizing_policy cmd.sizing_policy in
    ( book_id,
      risk_budget_fraction,
      max_per_instrument_notional,
      max_gross_exposure,
      construction_source,
      sizing_policy )
  in
  match validated with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok
      ( book_id,
        risk_budget_fraction,
        max_per_instrument_notional,
        max_gross_exposure,
        construction_source,
        sizing_policy ) -> (
      match
        build_risk_config ~book_id ~risk_budget_fraction ~max_per_instrument_notional
          ~max_gross_exposure ~construction_source ~sizing_policy
      with
      | Error errs -> Error (List.map (fun e -> Validation e) errs)
      | Ok cfg ->
          persist_risk_config book_id cfg;
          Rop.succeed ())
