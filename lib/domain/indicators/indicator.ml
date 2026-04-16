(** Incremental streaming indicator: each indicator is a first-class value
    implementing [S]. The engine folds candles through it and reads the
    current output without recomputing history. Adding a new indicator is a
    new file implementing [S] and registering itself in [Registry]. *)

open Core

module type S = sig
  type state
  type output

  val name : string
  val init : unit -> state
  val update : state -> Candle.t -> state * output option
  val value : state -> output option
  val output_to_float : output -> float list
  (** Flattened numeric output — used by the server/UI. For scalar
      indicators, a single-element list; for MACD, three; for Bollinger,
      three; and so on. *)
end

type t = E : (module S with type state = 's and type output = 'o) * 's -> t
(** Existential wrapper: heterogenous indicators live in a single list. *)

let make (type s o) (module M : S with type state = s and type output = o) =
  E ((module M), M.init ())

let update (E ((module M), st)) c =
  let st', _ = M.update st c in
  E ((module M), st')

let value (E ((module M), st)) =
  match M.value st with
  | None -> None
  | Some v -> Some (M.name, M.output_to_float v)

let name (E ((module M), _)) = M.name
