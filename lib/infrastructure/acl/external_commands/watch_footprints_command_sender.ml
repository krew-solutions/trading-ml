let make ~bus : symbol:string -> boundary:string -> unit =
  let publish =
    Bus.publish
      (Bus.producer bus ~uri:"in-memory://order-flow.watch-footprints-command"
         ~serialize:(fun (v : Watch_footprints_command.t) ->
           Yojson.Safe.to_string (Watch_footprints_command.yojson_of_t v)))
  in
  fun ~symbol ~boundary ->
    let cmd : Watch_footprints_command.t = { symbol; boundary } in
    publish cmd
