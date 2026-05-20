let handle (ev : Lifecycle.t) : unit =
  Log.info "[finam ws] %s (%d) %s" ev.event ev.code ev.reason
