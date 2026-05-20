let handle (ev : Error.t) : unit =
  Log.warn "[finam ws] error %d %s: %s" ev.code ev.type_ ev.message
