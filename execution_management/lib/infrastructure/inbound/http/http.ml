(** HTTP route handlers for execution_management. The factory
    constructs the closures from the typed query / command
    handlers and closes them over the ticket_store; this module
    owns only the URL routing and JSON shape. *)

type cancel_result = Cancel_ok | Cancel_not_found | Cancel_invalid_payload of string

let json_response j : Inbound_http.Route.response =
  (200, `Response (Inbound_http.Response.json ~status:`OK j))

let not_found_response () : Inbound_http.Route.response =
  (404, `Response (Inbound_http.Response.json ~status:`Not_found (`Assoc [])))

let bad_request_response msg : Inbound_http.Route.response =
  ( 400,
    `Response
      (Inbound_http.Response.json ~status:`Bad_request
         (`Assoc [ ("error", `String msg) ])) )

let no_content_response () : Inbound_http.Route.response =
  (204, `Response (Inbound_http.Response.json ~status:`No_content (`Assoc [])))

let parse_ticket_id segment : int option =
  match int_of_string_opt segment with
  | Some n when n > 0 -> Some n
  | _ -> None

let read_body body : string = Eio.Buf_read.(parse_exn take_all) body ~max_size:Int.max_int

let make_handler ~get_order_ticket ~list_open_order_tickets ~cancel_order_ticket () :
    Inbound_http.Route.handler =
 fun request body ->
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  match (meth, String.split_on_char '/' path) with
  | `GET, [ ""; "api"; "order-tickets" ] ->
      Some (json_response (`List (list_open_order_tickets ())))
  | `GET, [ ""; "api"; "order-tickets"; segment ] -> (
      match parse_ticket_id segment with
      | None -> Some (not_found_response ())
      | Some ticket_id -> (
          match get_order_ticket ticket_id with
          | None -> Some (not_found_response ())
          | Some j -> Some (json_response j)))
  | `POST, [ ""; "api"; "order-tickets"; segment; "cancel" ] -> (
      match parse_ticket_id segment with
      | None -> Some (not_found_response ())
      | Some ticket_id -> (
          let raw = try read_body body with _ -> "" in
          match cancel_order_ticket ~ticket_id ~body:raw with
          | Cancel_ok -> Some (no_content_response ())
          | Cancel_not_found -> Some (not_found_response ())
          | Cancel_invalid_payload msg -> Some (bad_request_response msg)))
  | _ -> None
