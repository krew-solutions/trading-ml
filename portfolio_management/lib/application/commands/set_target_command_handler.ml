module Target_portfolio = Portfolio_management.Target_portfolio
module Shared = Portfolio_management.Shared

type validation_error =
  | Invalid_book_id of string
  | Invalid_source of string
  | Invalid_proposed_at of string
  | Invalid_instrument of string
  | Invalid_target_qty_format of string

let validation_error_to_string = function
  | Invalid_book_id s -> Printf.sprintf "invalid book_id: %S" s
  | Invalid_source s -> Printf.sprintf "invalid source: %S" s
  | Invalid_proposed_at s ->
      Printf.sprintf "invalid proposed_at (ISO-8601 expected): %S" s
  | Invalid_instrument s -> Printf.sprintf "invalid instrument: %S" s
  | Invalid_target_qty_format s -> Printf.sprintf "invalid target_qty format: %S" s

let apply_error_to_string = function
  | Target_portfolio.Book_id_mismatch { aggregate_book; proposal_book } ->
      Printf.sprintf "book_id mismatch: aggregate=%s, proposal=%s"
        (Shared.Book_id.to_string aggregate_book)
        (Shared.Book_id.to_string proposal_book)
  | Target_portfolio.Position_book_id_mismatch
      { proposal_book; position_instrument; position_book } ->
      Printf.sprintf "position book_id mismatch on %s: proposal=%s, position=%s"
        (Core.Instrument.to_qualified position_instrument)
        (Shared.Book_id.to_string proposal_book)
        (Shared.Book_id.to_string position_book)

type validated_position = { instrument : Core.Instrument.t; target_qty : Decimal.t }

type validated_set_target_command = {
  book_id : Shared.Book_id.t;
  source : string;
  proposed_at : int64;
  positions : validated_position list;
}

type handle_error =
  | Validation of validation_error
  | Apply of {
      attempted : validated_set_target_command;
      error : Target_portfolio.apply_error;
    }

let parse_book_id raw : (Shared.Book_id.t, validation_error) Rop.t =
  try Rop.succeed (Shared.Book_id.of_string raw)
  with Invalid_argument _ -> Rop.fail (Invalid_book_id raw)

let parse_source raw : (string, validation_error) Rop.t =
  let s = String.trim raw in
  if s = "" then Rop.fail (Invalid_source raw) else Rop.succeed s

let parse_proposed_at raw : (int64, validation_error) Rop.t =
  let parsed = Datetime.Iso8601.parse raw in
  if Int64.equal parsed 0L then Rop.fail (Invalid_proposed_at raw) else Rop.succeed parsed

let parse_instrument raw : (Core.Instrument.t, validation_error) Rop.t =
  try Rop.succeed (Core.Instrument.of_qualified raw)
  with Invalid_argument _ -> Rop.fail (Invalid_instrument raw)

(* target_qty is signed Decimal; non-positive is allowed. *)
let parse_target_qty raw : (Decimal.t, validation_error) Rop.t =
  match try Some (Decimal.of_string raw) with _ -> None with
  | Some d -> Rop.succeed d
  | None -> Rop.fail (Invalid_target_qty_format raw)

let validate_position (pos : Set_target_command.position) :
    (validated_position, validation_error) Rop.t =
  let open Rop in
  let+ instrument = parse_instrument pos.instrument
  and+ target_qty = parse_target_qty pos.target_qty in
  { instrument; target_qty }

let sequence_positions (rs : (validated_position, validation_error) Rop.t list) :
    (validated_position list, validation_error) Rop.t =
  List.fold_right
    (fun r acc ->
      let open Rop in
      let+ x = r and+ xs = acc in
      x :: xs)
    rs (Rop.succeed [])

let validate (cmd : Set_target_command.t) :
    (validated_set_target_command, validation_error) Rop.t =
  let open Rop in
  let+ book_id = parse_book_id cmd.book_id
  and+ source = parse_source cmd.source
  and+ proposed_at = parse_proposed_at cmd.proposed_at
  and+ positions = sequence_positions (List.map validate_position cmd.positions) in
  { book_id; source; proposed_at; positions }

let to_target_proposal (v : validated_set_target_command) : Shared.Target_proposal.t =
  let positions =
    List.map
      (fun (vp : validated_position) ->
        ({ book_id = v.book_id; instrument = vp.instrument; target_qty = vp.target_qty }
          : Shared.Target_position.t))
      v.positions
  in
  { book_id = v.book_id; positions; source = v.source; proposed_at = v.proposed_at }

let handle ~(target_portfolio : Target_portfolio.t ref) (cmd : Set_target_command.t) :
    (Target_portfolio.Events.Target_set.t, handle_error) Rop.t =
  match validate cmd with
  | Error errs -> Error (List.map (fun e -> Validation e) errs)
  | Ok v -> (
      let proposal = to_target_proposal v in
      match Target_portfolio.apply_proposal !target_portfolio proposal with
      | Ok (target_portfolio', domain_event) ->
          target_portfolio := target_portfolio';
          Rop.succeed domain_event
      | Error e -> Error [ Apply { attempted = v; error = e } ])
