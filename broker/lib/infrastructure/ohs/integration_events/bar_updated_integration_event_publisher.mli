(** Bus publisher for {!Broker_integration_events.Bar_updated_integration_event}.
    Sole entry point for emitting on the [broker.bar-updated] topic;
    no other code in the broker BC should reach into [Bus.publish]
    for this URI directly.

    Thin — no state, no filtering. Deduplication and monotonicity
    invariants live at the inbound ACL boundary
    ({!Acl_common.Stream_dedup} in each adapter), so this publisher
    sees only the already-clean stream. *)

val make :
  bus:Bus.bus -> Broker_integration_events.Bar_updated_integration_event.t -> unit
