module Ot = Execution_management.Order_ticket

let handle ~ticket (cmd : Ingest_volume_bar_command.t) ~now =
  let result =
    try
      let volume = Decimal.of_string cmd.bar_volume in
      let bar = Ot.Values.Volume_bar.make ~ts:cmd.bar_ts ~volume in
      let t', events = Ot.on_volume_bar ticket ~bar ~now in
      Ok (t', events)
    with Invalid_argument m -> Error (Command_error.Invalid_payload ("bar: " ^ m))
  in
  match result with
  | Ok x -> Rop.succeed x
  | Error e -> Rop.fail e
