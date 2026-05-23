(** Server-side inbound DTO mirror of an instrument view model.

    Structural fields lifted from the wire (four strings); the
    [to_domain] projection reconstructs the local
    [Core.Instrument.t] by passing each field through its
    Value-Object smart constructor ([Ticker.of_string],
    [Mic.of_string], [Isin.of_string], [Board.of_string]). Any
    field that fails its constructor raises — the caller (the
    ACL handler) wraps the call in [try _ with _ -> ...] and
    drops the malformed payload with a warn log.

    No [of_domain] / outbound direction: this DTO is consumed
    (deserialized from an upstream BC's outbound JSON), not
    produced from a server domain value.

    Wire shape regenerated from the producer's .atd contract. *)

include module type of Instrument_view_model_t
include module type of Instrument_view_model_j with type t := t

val yojson_of_t : t -> Yojson.Safe.t
val t_of_yojson : Yojson.Safe.t -> t

type domain = Core.Instrument.t

val to_domain : t -> domain
(** Reconstruct the local domain value from the wire DTO. Raises
    if any field fails its Value-Object smart constructor. *)
