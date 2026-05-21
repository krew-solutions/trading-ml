(** Execution_management inbound HTTP routes.

    Routes:
    - [GET  /api/order-tickets]                  — list every non-terminal OrderTicket
    - [GET  /api/order-tickets/{id}]             — fetch a single OrderTicket
    - [POST /api/order-tickets/{id}/cancel]      — operator cancel

    The cancel route accepts the JSON wire shape of
    [Cancel_order_ticket_command.t] in the request body
    (omit [ticket_id] — the route segment is authoritative). The
    handler returns:
    - 204 No Content on a successful cancel dispatch
    - 404 Not Found when the ticket id is unknown
    - 400 Bad Request when the payload is malformed

    Future surfaces: kill-switch reset endpoint, saga-progress SSE
    channel filtered by correlation_id. *)

type cancel_result = Cancel_ok | Cancel_not_found | Cancel_invalid_payload of string

val make_handler :
  get_order_ticket:(int -> Yojson.Safe.t option) ->
  list_open_order_tickets:(unit -> Yojson.Safe.t list) ->
  cancel_order_ticket:(ticket_id:int -> body:string -> cancel_result) ->
  unit ->
  Inbound_http.Route.handler
