(** Shared payload utilities for Finam WS event parsing.

    Sibling module of {!Ws} (not nested inside) so that
    [Events.*] can reference these helpers without forcing a
    parent-module forward reference in the wrapped-library
    compile order. *)

val unwrap : Yojson.Safe.t -> Yojson.Safe.t
(** Finam's gRPC→REST bridge double-encodes [payload] as a
    JSON string in some channels (the gRPC wrapper type
    [google.protobuf.Value] renders nested messages as JSON
    text). [unwrap] returns the inner object when this happens,
    or the value itself if it's already an object. *)
