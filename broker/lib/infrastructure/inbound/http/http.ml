open Core

let exchanges_json ~default_board (broker : Broker.client) : Yojson.Safe.t =
  let venues =
    try Broker.venues broker
    with e ->
      Log.warn "%s venues failed: %s" (Broker.name broker) (Printexc.to_string e);
      []
  in
  `Assoc
    ([ ("exchanges", `List (List.map (fun m -> `String (Mic.to_string m)) venues)) ]
    @
    match default_board with
    | Some b -> [ ("default_board", `String b) ]
    | None -> [])

let make_handler ~broker ~default_board : Inbound_http.Route.handler =
 fun request _body ->
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  let json j = Some (200, `Response (Inbound_http.Response.json ~status:`OK j)) in
  match (meth, path) with
  | `GET, "/api/exchanges" -> json (exchanges_json ~default_board broker)
  | _ -> None
