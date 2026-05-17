module Ot = Execution_management.Order_ticket
module Values = Ot.Values

let parse_side = function
  | "BUY" | "buy" | "Buy" -> Ok Core.Side.Buy
  | "SELL" | "sell" | "Sell" -> Ok Core.Side.Sell
  | s -> Error (Command_error.Invalid_payload ("unknown side: " ^ s))

let parse_quantity s =
  try Ok (Decimal.of_string s)
  with Invalid_argument m ->
    Error (Command_error.Invalid_payload ("quantity: " ^ m))

let parse_instrument s =
  try Ok (Core.Instrument.of_qualified s)
  with Invalid_argument m ->
    Error (Command_error.Invalid_payload ("symbol: " ^ m))

let parse_ticket_id n =
  try Ok (Values.Ticket_id.of_int n)
  with Invalid_argument m ->
    Error (Command_error.Invalid_payload ("reservation_id: " ^ m))

let handle ~now (cmd : Open_order_ticket_command.t) =
  let ( let* ) = Result.bind in
  let result =
    let* side = parse_side cmd.side in
    let* quantity = parse_quantity cmd.quantity in
    let* instrument = parse_instrument cmd.symbol in
    let* ticket_id = parse_ticket_id cmd.reservation_id in
    let intent =
      Values.Trade_intent.make ~book_id:cmd.book_id ~instrument ~side
        ~total_quantity:quantity
    in
    let directive = Values.Execution_directive.Immediate in
    let t, events = Ot.open_ticket ~ticket_id ~intent ~directive ~now in
    Ok (t, events)
  in
  match result with
  | Ok x -> Rop.succeed x
  | Error e -> Rop.fail e
