(** Strategy signature: stream candles in, emit Signal.t decisions out.
    Strategies are explicit state machines with no global mutable state, so
    they are trivially deterministic — identical inputs always yield
    identical outputs. This is a property we rely on for backtesting and
    formal reasoning. *)

open Core

module type S = sig
  type state
  type params

  val name : string
  val default_params : params
  val init : params -> state

  val on_candle :
    state -> Symbol.t -> Candle.t -> state * Signal.t
end

type t =
  E : (module S with type state = 's and type params = 'p) * 's -> t

let make (type s p)
    (module M : S with type state = s and type params = p)
    (params : p) : t =
  E ((module M), M.init params)

let default (type s p)
    (module M : S with type state = s and type params = p) : t =
  E ((module M), M.init M.default_params)

let on_candle (E ((module M), st)) symbol candle =
  let st', sig_ = M.on_candle st symbol candle in
  E ((module M), st'), sig_

let name (E ((module M), _)) = M.name
