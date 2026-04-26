(** Trade direction. *)

type t = Buy | Sell

val to_string : t -> string

val of_string : string -> t
(** Accepts [BUY|buy|Buy|SELL|sell|Sell]; raises [Invalid_argument]
    on any other input. *)
(*@ r = of_string s
    raises Invalid_argument _ -> true *)

val opposite : t -> t
(*@ r = opposite s
    ensures match s with Buy -> r = Sell | Sell -> r = Buy *)

val sign : t -> int
(** Cash-flow direction: [Buy] consumes cash (+1 for "we owe / outflow"),
    [Sell] frees cash (-1). Reservations scale cash impact by this sign. *)
(*@ r = sign s
    ensures match s with Buy -> r = 1 | Sell -> r = -1 *)
