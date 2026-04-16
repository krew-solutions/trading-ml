(** OHLCV bar. Invariants enforced by the smart constructor. *)

type t = private {
  ts : int64;       (** open time, unix epoch seconds (UTC) *)
  open_ : Decimal.t;
  high : Decimal.t;
  low : Decimal.t;
  close : Decimal.t;
  volume : Decimal.t;
}

val make :
  ts:int64 ->
  open_:Decimal.t ->
  high:Decimal.t ->
  low:Decimal.t ->
  close:Decimal.t ->
  volume:Decimal.t ->
  t
(** Raises [Invalid_argument] when invariants are violated:
    - [low <= open_,close <= high]
    - [volume >= 0] *)
(*@ c = make ~ts ~open_ ~high ~low ~close ~volume
    raises Invalid_argument _ -> true *)

val typical : t -> Decimal.t
(** [(high + low + close) / 3] — the typical price used by many indicators. *)

val median : t -> Decimal.t
(** [(high + low) / 2]. *)

val range : t -> Decimal.t
(** [high - low]. *)

val is_bull : t -> bool
val is_bear : t -> bool

