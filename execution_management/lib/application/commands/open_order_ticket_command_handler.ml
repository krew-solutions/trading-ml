module Ot = Execution_management.Order_ticket
module Values = Ot.Values

let parse_side = function
  | "BUY" | "buy" | "Buy" -> Ok Core.Side.Buy
  | "SELL" | "sell" | "Sell" -> Ok Core.Side.Sell
  | s -> Error (Command_error.Invalid_payload ("unknown side: " ^ s))

let parse_quantity s =
  try Ok (Decimal.of_string s)
  with Invalid_argument m -> Error (Command_error.Invalid_payload ("quantity: " ^ m))

let parse_instrument s =
  try Ok (Core.Instrument.of_qualified s)
  with Invalid_argument m -> Error (Command_error.Invalid_payload ("symbol: " ^ m))

let parse_ticket_id n =
  try Ok (Values.Ticket_id.of_int n)
  with Invalid_argument m ->
    Error (Command_error.Invalid_payload ("reservation_id (as ticket_id): " ^ m))

let parse_reservation_id n =
  try Ok (Values.Reservation_id.of_int n)
  with Invalid_argument m ->
    Error (Command_error.Invalid_payload ("reservation_id: " ^ m))

(** Wire directive parser.

    The wire shape is [(kind : string) * (params : string option)]
    where [params] is an opaque JSON-object string. The parser is
    the boundary that turns it into the typed
    [Values.Execution_directive.t]; per-strategy params are
    type-checked here, so the aggregate downstream receives only
    well-formed values.

    The parser is permissive on the kind casing (IMMEDIATE / immediate
    / Immediate) to match the rest of the BC. *)
let parse_int64_field json key =
  let open Yojson.Safe.Util in
  match member key json with
  | `Int n -> Ok (Int64.of_int n)
  | `Intlit s -> (
      try Ok (Int64.of_string s)
      with _ -> Error (Command_error.Invalid_payload (key ^ ": not an integer")))
  | _ -> Error (Command_error.Invalid_payload (key ^ ": missing or wrong type"))

let parse_int_field json key =
  let open Yojson.Safe.Util in
  match member key json with
  | `Int n -> Ok n
  | _ -> Error (Command_error.Invalid_payload (key ^ ": missing or wrong type"))

let parse_float_field json key =
  let open Yojson.Safe.Util in
  match member key json with
  | `Float f -> Ok f
  | `Int n -> Ok (float_of_int n)
  | _ -> Error (Command_error.Invalid_payload (key ^ ": missing or wrong type"))

let parse_decimal_string_field json key =
  let open Yojson.Safe.Util in
  match member key json with
  | `String s -> (
      try Ok (Decimal.of_string s)
      with Invalid_argument m -> Error (Command_error.Invalid_payload (key ^ ": " ^ m)))
  | _ -> Error (Command_error.Invalid_payload (key ^ ": missing or wrong type"))

let parse_string_field json key =
  let open Yojson.Safe.Util in
  match member key json with
  | `String s when s <> "" -> Ok s
  | `String _ -> Error (Command_error.Invalid_payload (key ^ ": empty string"))
  | _ -> Error (Command_error.Invalid_payload (key ^ ": missing or wrong type"))

let parse_float_list_field json key =
  let open Yojson.Safe.Util in
  match member key json with
  | `List items ->
      let coerce = function
        | `Float f -> Some f
        | `Int n -> Some (float_of_int n)
        | _ -> None
      in
      let rec collect = function
        | [] -> Ok []
        | x :: xs -> (
            match coerce x with
            | None ->
                Error (Command_error.Invalid_payload (key ^ ": non-numeric element"))
            | Some f -> (
                match collect xs with
                | Error e -> Error e
                | Ok rest -> Ok (f :: rest)))
      in
      collect items
  | _ -> Error (Command_error.Invalid_payload (key ^ ": missing or wrong type"))

let parse_directive (d : Open_order_ticket_command.directive) :
    (Values.Execution_directive.t, Command_error.t) result =
  let kind = String.uppercase_ascii d.kind in
  let require_params msg =
    match d.params with
    | None -> Error (Command_error.Invalid_payload msg)
    | Some s -> (
        try Ok (Yojson.Safe.from_string s)
        with _ ->
          Error (Command_error.Invalid_payload (msg ^ ": params blob is not JSON")))
  in
  let ( let* ) = Result.bind in
  let make_invalid m = Command_error.Invalid_payload m in
  match kind with
  | "IMMEDIATE" -> Ok Values.Execution_directive.Immediate
  | "TWAP" -> (
      let* json = require_params "TWAP requires params" in
      let* n_slices = parse_int_field json "n_slices" in
      let* window_seconds = parse_int_field json "window_seconds" in
      let* start_at = parse_int64_field json "start_at" in
      try
        Ok
          (Values.Execution_directive.Twap
             (Values.Twap_params.make ~n_slices ~window_seconds ~start_at))
      with Invalid_argument m -> Error (make_invalid ("TWAP params: " ^ m)))
  | "VWAP" -> (
      let* json = require_params "VWAP requires params" in
      let* n_slices = parse_int_field json "n_slices" in
      let* window_seconds = parse_int_field json "window_seconds" in
      let* start_at = parse_int64_field json "start_at" in
      let* volume_profile = parse_float_list_field json "volume_profile" in
      try
        Ok
          (Values.Execution_directive.Vwap
             (Values.Vwap_params.make ~n_slices ~window_seconds ~start_at ~volume_profile))
      with Invalid_argument m -> Error (make_invalid ("VWAP params: " ^ m)))
  | "POV" -> (
      let* json = require_params "POV requires params" in
      let* participation_rate = parse_float_field json "participation_rate" in
      let* timeframe = parse_string_field json "timeframe" in
      try
        Ok
          (Values.Execution_directive.Pov
             (Values.Pov_params.make ~participation_rate ~timeframe))
      with Invalid_argument m -> Error (make_invalid ("POV params: " ^ m)))
  | "ICEBERG" -> (
      let* json = require_params "ICEBERG requires params" in
      let* visible_qty = parse_decimal_string_field json "visible_qty" in
      try
        Ok (Values.Execution_directive.Iceberg (Values.Iceberg_params.make ~visible_qty))
      with Invalid_argument m -> Error (make_invalid ("ICEBERG params: " ^ m)))
  | "IMPLEMENTATION_SHORTFALL" -> (
      let* json = require_params "IMPLEMENTATION_SHORTFALL requires params" in
      let* n_slices = parse_int_field json "n_slices" in
      let* window_seconds = parse_int_field json "window_seconds" in
      let* start_at = parse_int64_field json "start_at" in
      let* volatility = parse_float_field json "volatility" in
      let* risk_aversion = parse_float_field json "risk_aversion" in
      let* temp_impact_eta = parse_float_field json "temp_impact_eta" in
      try
        Ok
          (Values.Execution_directive.Implementation_shortfall
             (Values.Implementation_shortfall_params.make ~n_slices ~window_seconds
                ~start_at ~volatility ~risk_aversion ~temp_impact_eta))
      with Invalid_argument m ->
        Error (make_invalid ("IMPLEMENTATION_SHORTFALL params: " ^ m)))
  | k -> Error (make_invalid ("unknown execution directive kind: " ^ k))

let resolve_directive :
    Open_order_ticket_command.directive option ->
    (Values.Execution_directive.t, Command_error.t) result = function
  | None -> Ok Values.Execution_policy.default
  | Some d -> parse_directive d

let handle ~now (cmd : Open_order_ticket_command.t) =
  let ( let* ) = Result.bind in
  let result =
    let* side = parse_side cmd.side in
    let* quantity = parse_quantity cmd.quantity in
    let* instrument = parse_instrument cmd.symbol in
    let* ticket_id = parse_ticket_id cmd.reservation_id in
    let* reservation_id = parse_reservation_id cmd.reservation_id in
    let* directive = resolve_directive cmd.execution_directive in
    let intent =
      Values.Trade_intent.make ~book_id:cmd.book_id ~instrument ~side
        ~total_quantity:quantity
    in
    let t, events = Ot.open_ticket ~ticket_id ~reservation_id ~intent ~directive ~now in
    Ok (t, events)
  in
  match result with
  | Ok x -> Rop.succeed x
  | Error e -> Rop.fail e
