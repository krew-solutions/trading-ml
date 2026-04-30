type response = int * Cohttp_eio.Server.response_action
type handler = Cohttp.Request.t -> Cohttp_eio.Body.t -> response option
