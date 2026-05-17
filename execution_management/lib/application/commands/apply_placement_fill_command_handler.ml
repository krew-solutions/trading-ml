module Ot = Execution_management.Order_ticket

let parse_decimal field s =
  try Ok (Decimal.of_string s)
  with Invalid_argument m ->
    Error (Command_error.Invalid_payload (field ^ ": " ^ m))

let handle ~ticket (cmd : Apply_placement_fill_command.t) ~now =
  let ( let* ) = Result.bind in
  let result =
    let* pid =
      try Ok (Ot.Placement.Values.Placement_id.of_int cmd.placement_id)
      with Invalid_argument m ->
        Error (Command_error.Invalid_payload ("placement_id: " ^ m))
    in
    let* quantity = parse_decimal "fill_quantity" cmd.fill_quantity in
    let* price = parse_decimal "fill_price" cmd.fill_price in
    let* fee = parse_decimal "fee" cmd.fee in
    let* fill =
      try
        Ok
          (Ot.Placement.Values.Fill_record.make ~quantity ~price ~fee
             ~ts:cmd.fill_ts)
      with Invalid_argument m ->
        Error (Command_error.Invalid_payload ("fill: " ^ m))
    in
    let* result =
      try
        let t', events = Ot.on_placement_fill ticket ~placement_id:pid ~fill ~now in
        Ok (t', events)
      with Invalid_argument m -> Error (Command_error.Domain_violation m)
    in
    Ok result
  in
  match result with
  | Ok x -> Rop.succeed x
  | Error e -> Rop.fail e
