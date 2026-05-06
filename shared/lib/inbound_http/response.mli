(** Common response builders for inbound HTTP handlers. CORS headers
    are open for the localhost Angular dev server; tighten at the
    edge (reverse proxy) in production. *)

val json : ?status:Cohttp.Code.status_code -> Yojson.Safe.t -> Cohttp_eio.Server.response

val text : ?status:Cohttp.Code.status_code -> string -> Cohttp_eio.Server.response
