module Footprint_completed_ie =
  Order_flow_integration_events.Footprint_completed_integration_event

let get_query uri k =
  match Uri.get_query_param uri k with
  | Some v -> v
  | None -> ""

let get_query_int uri k d =
  match Uri.get_query_param uri k with
  | Some s -> ( try int_of_string s with _ -> d)
  | None -> d

(* { "footprints": [ <footprint_completed DTO>, … ] } — each element is
   the very payload the footprint-completed integration event carries
   (one immutable fact, served over pull here and push over SSE), so the
   query reuses that wire shape rather than minting a byte-identical
   view model. *)
let footprints_json (xs : Footprint_completed_ie.t list) : Yojson.Safe.t =
  `Assoc [ ("footprints", `List (List.map Footprint_completed_ie.yojson_of_t xs)) ]

let make_handler ~(history : Footprint_history.t) : Inbound_http.Route.handler =
 fun request _body ->
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  match (meth, path) with
  | `GET, "/api/footprints" ->
      let symbol = get_query uri "symbol" in
      let timeframe =
        match get_query uri "timeframe" with
        | "" -> "M5"
        | s -> s
      in
      let n = get_query_int uri "n" 200 in
      let xs = Footprint_history.recent history ~symbol ~timeframe ~n in
      Some (200, `Response (Inbound_http.Response.json (footprints_json xs)))
  | _ -> None
