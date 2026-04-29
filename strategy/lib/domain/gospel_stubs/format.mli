(** Stub for gospel's load path: [Format] is absent from gospel 0.3.1's
    stdlib and any reference to [Format.formatter] crashes the
    type-checker. Declaring the type here unblocks [.mli] files that
    export [val pp : Format.formatter -> t -> unit]. Not used at OCaml
    compile time — dune never sees this directory as a library. *)

type formatter
