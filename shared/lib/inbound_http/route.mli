(** Per-Bounded-Context HTTP route handler contract.

    Each BC's [inbound/http] module composes its routes into a single
    {!handler} that returns [Some] when it owns the request and [None]
    otherwise. The composition root passes a list of such handlers to
    the core HTTP server, which tries them in order before falling
    back to its built-in routes (and finally a 404). This is the only
    HTTP-level dependency the core has on a BC. *)

type response = int * Cohttp_eio.Server.response_action
(** Status code paired with the cohttp-eio response action. The status
    is logged uniformly by the core server; the action carries the
    actual response body (or an [`Expert] streaming handler for SSE). *)

type handler = Cohttp.Request.t -> Cohttp_eio.Body.t -> response option
(** [None] declines the request — try the next handler. *)
