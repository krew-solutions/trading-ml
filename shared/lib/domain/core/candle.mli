(** OHLCV bar. Invariants enforced by the smart constructor. *)

(*@ function dec_raw (d : Decimal.t) : integer *)
(** Local alias for the scaled-integer projection of [Decimal.t]. Gospel
    0.3.1 doesn't carry [model] declarations across files; this stub
    gives us a handle on [Decimal.t]'s value in specs below. Once
    cross-file models are supported we can drop it. *)

type t = private {
  ts : int64;  (** open time, unix epoch seconds (UTC) *)
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
    raises Invalid_argument _ ->
      not (dec_raw low <= dec_raw open_
           /\ dec_raw open_ <= dec_raw high
           /\ dec_raw low <= dec_raw close
           /\ dec_raw close <= dec_raw high
           /\ dec_raw volume >= 0) *)

val typical : t -> Decimal.t
(** [(high + low + close) / 3] — the typical price used by many indicators. *)

val median : t -> Decimal.t
(** [(high + low) / 2]. *)

val range : t -> Decimal.t
(** [high - low]. Always non-negative by construction — [make]
    rejects [low > high]. *)
(*@ r = range c
    ensures dec_raw r = dec_raw c.high - dec_raw c.low *)

val is_bull : t -> bool
(*@ r = is_bull c
    ensures r <-> dec_raw c.close > dec_raw c.open_ *)

val is_bear : t -> bool
(*@ r = is_bear c
    ensures r <-> dec_raw c.close < dec_raw c.open_ *)
