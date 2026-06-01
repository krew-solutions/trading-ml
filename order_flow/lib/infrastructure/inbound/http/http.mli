(** order_flow BC inbound HTTP routes.

    Today exposes one read endpoint:

      GET /api/footprints?symbol=TICKER@MIC[/BOARD]&timeframe=<token>&n=N
          The up-to-[N] most recently sealed footprints for the
          instrument under the given boundary, oldest-first — the pull
          counterpart to the push-side footprint-completed SSE stream.
          [timeframe] is the boundary token as it appears on the wire
          ("M5", "VOL:<cap>"; default "M5"); [n] defaults to 200.
          Returns [{ "footprints": [ <footprint_completed>, … ] }],
          each element the same DTO the integration event carries.

    The handler is built at the composition root over a
    {!Footprint_history.t} fed from the BC's own sealed-footprint
    stream, and registered with the core HTTP server through
    {!Inbound_http.Route.handler}. *)

val make_handler : history:Footprint_history.t -> Inbound_http.Route.handler
