(** [Remote_broker] — the external broker (Finam, BCS, ...) **as
    observed through our adapter**. This is not a behaviour-bearing
    aggregate of our domain: we never submit a transition to it, we
    only recognise facts that the broker reports to us (one fill
    leg observed, an acknowledgement, a rejection, a bar, ...).
    Some of these facts originate at the venue (matching, price
    discovery) and reach us via the broker; others are
    broker-originated (pre-trade kill-switch rejection, account
    unauthorized). Either way, the broker is what we observe — it
    is our integration boundary.

    Per Vernon's "external system as a source of Domain Events"
    pattern, the adapter (ACL) acts as the recognizer: it receives
    the broker's wire frame, translates it into a Domain Event in
    this aggregate's vocabulary, and dispatches.

    Kept distinct from any future *local* [Order] aggregate that
    would model OUR system's intent and lifecycle (submit, cancel,
    amend — with its own emit-able events). The two concepts share
    [placement_id] as identity: [Order] expresses what we asked
    for, [Remote_broker] events express what the broker reports
    back. *)

module Events : module type of Events
