(** Inbound CQRS command to (re)configure a book's
    {!Portfolio_management.Risk_config.t}. Persists the
    aggregate into the per-book registry consulted by the
    unified construction → sizing → clipping pipeline.

    Wire shape mirrors {!Configure_risk_command_t.t}; this
    module re-exports the ATD-generated type and its
    Yojson <-> string projections so callers do not need to
    know about the [_t]/[_j] split. *)

include module type of struct
  include Configure_risk_command_t
  include Configure_risk_command_j
end

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t
