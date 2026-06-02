let make ~bus : symbol:string -> boundary:string -> unit =
  let publish =
    Bus.publish
      (Bus.producer bus ~uri:"in-memory://order-flow.unwatch-footprints-command"
         ~serialize:(fun (v : Unwatch_footprints_command.t) ->
           Yojson.Safe.to_string (Unwatch_footprints_command.yojson_of_t v)))
  in
  fun ~symbol ~boundary ->
    let cmd : Unwatch_footprints_command.t = { symbol; boundary } in
    publish cmd
