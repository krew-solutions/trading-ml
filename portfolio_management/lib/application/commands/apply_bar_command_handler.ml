module Pair_mean_reversion = Portfolio_management.Pair_mean_reversion
module Common = Portfolio_management.Common

type validation_error =
  | Invalid_instrument of string
  | Invalid_decimal of { field : string; value : string }
  | Invalid_candle of string

let validation_error_to_string = function
  | Invalid_instrument s -> Printf.sprintf "invalid instrument: %S" s
  | Invalid_decimal { field; value } ->
      Printf.sprintf "invalid decimal for %s: %S" field value
  | Invalid_candle s -> Printf.sprintf "invalid candle: %s" s

type handle_error = Validation of validation_error

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_instrument raw)

let parse_decimal ~field raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (Invalid_decimal { field; value = raw })

let parse_candle (bar : Apply_bar_command.bar_dto) :
    (Core.Candle.t, validation_error) Rop.t =
  let parsed_decimals =
    let open Rop in
    let+ open_ = parse_decimal ~field:"open" bar.open_
    and+ high = parse_decimal ~field:"high" bar.high
    and+ low = parse_decimal ~field:"low" bar.low
    and+ close = parse_decimal ~field:"close" bar.close
    and+ volume = parse_decimal ~field:"volume" bar.volume in
    (open_, high, low, close, volume)
  in
  match parsed_decimals with
  | Error _ as e -> e
  | Ok (open_, high, low, close, volume) -> (
      try Rop.succeed (Core.Candle.make ~ts:bar.ts ~open_ ~high ~low ~close ~volume)
      with Invalid_argument msg -> Rop.fail (Invalid_candle msg))

let handle
    ~(pair_mr_states_for : Core.Instrument.t -> Pair_mean_reversion.state ref list)
    (cmd : Apply_bar_command.t) : (Common.Target_proposal.t list, handle_error) Rop.t =
  let parsed =
    let open Rop in
    let+ instrument = parse_instrument cmd.instrument
    and+ candle = parse_candle cmd.bar in
    (instrument, candle)
  in
  match parsed with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok (instrument, candle) ->
      let proposals =
        List.fold_left
          (fun acc state_ref ->
            let state', proposal_opt =
              Pair_mean_reversion.on_bar !state_ref ~instrument ~candle
            in
            state_ref := state';
            match proposal_opt with
            | Some p -> p :: acc
            | None -> acc)
          []
          (pair_mr_states_for instrument)
      in
      Rop.succeed (List.rev proposals)
