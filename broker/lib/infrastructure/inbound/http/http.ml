open Core

let order_json (o : Order.t) : Yojson.Safe.t =
  Broker_queries.Order_view_model.yojson_of_t
    (Broker_queries.Order_view_model.of_domain o)

let orders_json (os : Order.t list) : Yojson.Safe.t =
  `Assoc [ ("orders", `List (List.map order_json os)) ]

let exchanges_json (broker : Broker.client) : Yojson.Safe.t =
  let venues =
    try Broker.venues broker
    with e ->
      Log.warn "%s venues failed: %s" (Broker.name broker) (Printexc.to_string e);
      []
  in
  `Assoc [ ("exchanges", `List (List.map (fun m -> `String (Mic.to_string m)) venues)) ]

let orders_prefix = "/api/orders/"

let strip_orders_prefix path =
  let plen = String.length orders_prefix in
  if String.length path > plen && String.sub path 0 plen = orders_prefix then
    Some (String.sub path plen (String.length path - plen))
  else None

let make_handler ~broker : Inbound_http.Route.handler =
 fun request _body ->
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  let json j = Some (200, `Response (Inbound_http.Response.json ~status:`OK j)) in
  match (meth, path) with
  | `GET, "/api/orders" -> json (orders_json (Broker.get_orders broker))
  | `GET, "/api/exchanges" -> json (exchanges_json broker)
  | `GET, _ -> (
      match strip_orders_prefix path with
      | Some cid -> json (order_json (Broker.get_order broker ~client_order_id:cid))
      | None -> None)
  | `DELETE, _ -> (
      match strip_orders_prefix path with
      | Some cid -> json (order_json (Broker.cancel_order broker ~client_order_id:cid))
      | None -> None)
  | _ -> None
