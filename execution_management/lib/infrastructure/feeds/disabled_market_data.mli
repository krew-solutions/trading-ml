(** {!Market_data_port.S} adapter that accepts subscriptions and
    never emits — mirrors {!Disabled_volume_feed} for the
    market_data feed that future Implementation-Shortfall
    adaptive logic will consume. *)

include Execution_management_ports.Market_data_port.S

val create : unit -> unit
