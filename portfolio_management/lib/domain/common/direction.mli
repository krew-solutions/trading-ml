(** Directional bias of an alpha source on an instrument.

    - [Up]   — bullish forecast: target a long position.
    - [Down] — bearish forecast: target a short position.
    - [Flat] — no edge: target zero exposure.

    Produced by an alpha source's analysis of a bar; consumed by
    Portfolio Construction policies as the directional input to
    sizing. Mirrors LEAN's [InsightDirection]: deliberately decoupled
    from entry/exit semantics — the source declares its directional
    view, and the portfolio decides what trade follows from comparing
    that view against current positions. *)

type t = Up | Down | Flat

val sign : t -> int
(** [+1] for [Up], [-1] for [Down], [0] for [Flat]. Used by sizing
    code to apply direction to a notional. *)

val to_string : t -> string
(** ["UP"] | ["DOWN"] | ["FLAT"]. *)

val of_string : string -> t
(** Inverse of {!to_string}; case-insensitive. Raises
    [Invalid_argument] on any other input. *)

val equal : t -> t -> bool
