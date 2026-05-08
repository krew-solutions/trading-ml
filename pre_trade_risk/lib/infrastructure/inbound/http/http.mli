(** Pre_trade_risk inbound HTTP routes. Stub today — every request
    returns [None]. The factory still exposes an [http_handler] field
    for uniformity with the other BCs. *)

val make_handler : unit -> Inbound_http.Route.handler
