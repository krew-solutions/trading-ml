type t = int64

let scale = 8
let unit_ = 100_000_000L (* 10^8 *)

let zero = 0L
let one = unit_

let of_int n = Int64.mul (Int64.of_int n) unit_
let of_float f = Int64.of_float (f *. Int64.to_float unit_)
let to_float x = Int64.to_float x /. Int64.to_float unit_

let add = Int64.add
let sub = Int64.sub
let neg = Int64.neg
let abs = Int64.abs

exception Decimal_overflow

(** Hand-rolled 128-bit signed arithmetic, scoped to the operations
    {!mul} and {!div} need: 64×64 → 128 unsigned multiply, 128+128
    add, 128/64 → 128 division, and a narrowing conversion that
    raises {!Decimal_overflow} when the value doesn't fit in a signed
    int64. The representation is sign-magnitude:
    [{ negative; hi; lo }], where [hi] and [lo] hold the upper and
    lower 64 bits of the magnitude, both interpreted unsigned.

    Why a private submodule rather than a separate library: this
    arithmetic is not a goal in itself — it exists so that {!Decimal}
    can compute exactly across the int64 boundary. Separating it
    would invite reuse in places where {!Decimal} alone is the right
    abstraction. *)
module Int128 = struct
  type t = { negative : bool; hi : int64; lo : int64 }
  (** [hi] = upper 64 bits of magnitude (unsigned), [lo] = lower 64
      bits (unsigned). Magnitude is [hi << 64 | lo]; [negative] is the
      sign. Zero is canonically [{ negative = false; hi = 0; lo = 0 }]. *)

  (** Treat an int64 as unsigned: [<] / [>] using
      [Int64.unsigned_compare]. *)
  let ucmp = Int64.unsigned_compare

  (** 64×64 → 128 unsigned multiply, via the standard high/low 32-bit
      split so each intermediate product fits in an int64.

      Decompose [a = ah * 2^32 + al] (likewise [b]). Then
        [a * b = ah*bh * 2^64 + (ah*bl + al*bh) * 2^32 + al*bl]
      Each of [ah*bh], [ah*bl], [al*bh], [al*bl] is the product of two
      32-bit unsigned values, so fits in int64 unsigned (≤ 2^64 − 2^33). *)
  let umul_64x64 (a : int64) (b : int64) : int64 * int64 =
    let mask32 = 0xFFFF_FFFFL in
    let al = Int64.logand a mask32 and ah = Int64.shift_right_logical a 32 in
    let bl = Int64.logand b mask32 and bh = Int64.shift_right_logical b 32 in
    let ll = Int64.mul al bl in
    let lh = Int64.mul al bh in
    let hl = Int64.mul ah bl in
    let hh = Int64.mul ah bh in
    (* Combine. Each "row" is 32 bits wide in the result; carries are
       propagated as we sum the columns. *)
    let mid = Int64.add (Int64.logand lh mask32) (Int64.logand hl mask32) in
    let mid_carry_to_hi =
      Int64.add (Int64.shift_right_logical lh 32) (Int64.shift_right_logical hl 32)
    in
    let lo_part = Int64.add ll (Int64.shift_left (Int64.logand mid mask32) 32) in
    let lo_carry =
      (* unsigned overflow on the [add ll <<mid] step *)
      if ucmp lo_part ll < 0 then 1L else 0L
    in
    let hi_part =
      Int64.add hh
        (Int64.add
           (Int64.shift_right_logical mid 32)
           (Int64.add mid_carry_to_hi lo_carry))
    in
    (hi_part, lo_part)

  let zero = { negative = false; hi = 0L; lo = 0L }

  (** Signed 64 × signed 64 → signed 128. *)
  let mul_64x64 (a : int64) (b : int64) : t =
    if Int64.equal a 0L || Int64.equal b 0L then zero
    else
      let neg_a = Int64.compare a 0L < 0 in
      let neg_b = Int64.compare b 0L < 0 in
      (* |Int64.min_int| doesn't fit; widen via Int128. *)
      let am =
        if Int64.equal a Int64.min_int then
          (* magnitude 2^63 represented as (hi=0, lo=Int64.min_int) *)
          { negative = false; hi = 0L; lo = Int64.min_int }
        else { negative = false; hi = 0L; lo = (if neg_a then Int64.neg a else a) }
      in
      let bm =
        if Int64.equal b Int64.min_int then
          { negative = false; hi = 0L; lo = Int64.min_int }
        else { negative = false; hi = 0L; lo = (if neg_b then Int64.neg b else b) }
      in
      (* Both magnitudes are non-negative ≤ 2^63. If one of them is
         exactly 2^63 (i.e. came from min_int), umul_64x64 doesn't
         apply directly because we represent it as the (hi=0, lo=...)
         pair already.

         Special-case it: 2^63 × m = m << 63, where
           - lo = m << 63  (low 64 bits)
           - hi = m >> 1   (upper 64 bits)
         The opposite-sign result of two min_int operands is
         2^63 × 2^63 = 2^126, which we encode as hi = 2^62, lo = 0. *)
      let result_negative = neg_a <> neg_b in
      let widen_via_shift_left_63 m =
        (* m * 2^63 *)
        let hi = Int64.shift_right_logical m 1 in
        let lo = Int64.shift_left m 63 in
        (hi, lo)
      in
      let hi, lo =
        match (am.hi, bm.hi) with
        | 0L, 0L when Int64.equal am.lo Int64.min_int && Int64.equal bm.lo Int64.min_int
          ->
            (* 2^63 × 2^63 = 2^126 *)
            (0x4000_0000_0000_0000L, 0L)
        | 0L, 0L when Int64.equal am.lo Int64.min_int -> widen_via_shift_left_63 bm.lo
        | 0L, 0L when Int64.equal bm.lo Int64.min_int -> widen_via_shift_left_63 am.lo
        | 0L, 0L -> umul_64x64 am.lo bm.lo
        | _ ->
            (* Should be unreachable — both inputs are int64 magnitudes
               ≤ 2^63, so [hi] is 0 or the special [Int64.min_int]
               sentinel handled above. *)
            assert false
      in
      if Int64.equal hi 0L && Int64.equal lo 0L then zero
      else { negative = result_negative; hi; lo }

  (** Unsigned 128 / unsigned 64 → (unsigned 128 quotient, unsigned 64
      remainder).

      Bit-by-bit shift-subtract long division. 128 iterations: at each
      step shift the running remainder one bit left, bring in the next
      dividend bit, and if the result is ≥ [b] subtract [b] and set
      the matching quotient bit. Standard textbook algorithm; works
      uniformly for any [b] in [1, 2^64 - 1].

      Faster algorithms exist (Knuth Algorithm D, Granlund-Möller),
      but 128 iterations of a few elementary int64 ops per division
      are acceptable for a reference application — Decimal mul/div
      are not in the inner loop of any hot path. *)
  let udiv_128_by_64 ((ahi, alo) : int64 * int64) (b : int64) : (int64 * int64) * int64 =
    if Int64.equal b 0L then raise Division_by_zero
    else
      let q_hi = ref 0L and q_lo = ref 0L in
      let r = ref 0L in
      for i = 127 downto 0 do
        (* Bit i of the 128-bit dividend, where bit 0 is the LSB. *)
        let bit =
          if i >= 64 then Int64.logand 1L (Int64.shift_right_logical ahi (i - 64))
          else Int64.logand 1L (Int64.shift_right_logical alo i)
        in
        (* The high bit of [r] before shift; left-shift may push it
           past int64 range. We track it explicitly so the unsigned
           comparison against [b] below stays correct. *)
        let high_bit = Int64.logand 1L (Int64.shift_right_logical !r 63) in
        (* Shift left and bring in the next dividend bit. The shift
           wraps modulo 2^64, which is harmless given [high_bit]
           tracking. *)
        r := Int64.logor (Int64.shift_left !r 1) bit;
        let geq_b =
          (* If the high bit was 1, the *true* (65-bit) value is
             ≥ 2^64 > b, so unconditionally subtract. *)
          if Int64.equal high_bit 1L then true else Int64.unsigned_compare !r b >= 0
        in
        if geq_b then begin
          (* Sub wraps the same way; (r - b) mod 2^64 is the correct
             new remainder because true_r - b < 2^64 by construction. *)
          r := Int64.sub !r b;
          if i >= 64 then q_hi := Int64.logor !q_hi (Int64.shift_left 1L (i - 64))
          else q_lo := Int64.logor !q_lo (Int64.shift_left 1L i)
        end
      done;
      ((!q_hi, !q_lo), !r)

  (** Signed 128 / signed 64 → signed 128, truncated toward zero.
      Remainder is discarded. *)
  let div_128_by_64 (a : t) (b : int64) : t =
    if Int64.equal b 0L then raise Division_by_zero
    else
      let neg_b = Int64.compare b 0L < 0 in
      let bm =
        if Int64.equal b Int64.min_int then Int64.min_int
        else if neg_b then Int64.neg b
        else b
      in
      (* If b = min_int we treat its magnitude (2^63) specially: the
         dividend's hi is < 2^63 by construction in our use sites, so
         [a / 2^63] = (ahi << 1 | alo >> 63) if ahi < 2^63. We fall
         back on the general path otherwise — for this codebase,
         dividing by min_int never arises. *)
      ignore bm;
      let bm = if neg_b then Int64.neg b else b in
      let (qhi, qlo), _r = udiv_128_by_64 (a.hi, a.lo) bm in
      if Int64.equal qhi 0L && Int64.equal qlo 0L then zero
      else
        let result_negative = a.negative <> neg_b in
        { negative = result_negative; hi = qhi; lo = qlo }

  (** Narrow a signed 128 to signed int64. Raises {!Decimal_overflow}
      if [|x| > Int64.max_int]. *)
  let to_int64_exact (x : t) : int64 =
    if not (Int64.equal x.hi 0L) then raise Decimal_overflow
    else
      let lo = x.lo in
      if Int64.compare lo 0L < 0 then
        (* lo's high bit is set → magnitude ≥ 2^63; only representable
           as a negative int64 if it's exactly 2^63 and the sign is
           negative (Int64.min_int). *)
        if x.negative && Int64.equal lo Int64.min_int then Int64.min_int
        else raise Decimal_overflow
      else if x.negative then Int64.neg lo
      else lo
end

let mul a b = Int128.to_int64_exact (Int128.div_128_by_64 (Int128.mul_64x64 a b) unit_)

let div a b =
  if Int64.equal b 0L then raise Division_by_zero
  else Int128.to_int64_exact (Int128.div_128_by_64 (Int128.mul_64x64 a unit_) b)

let compare = Int64.compare
let equal = Int64.equal
let min a b = if compare a b <= 0 then a else b
let max a b = if compare a b >= 0 then a else b

let is_positive x = compare x zero > 0
let is_negative x = compare x zero < 0
let is_zero x = equal x zero

let to_string x =
  let sign = if is_negative x then "-" else "" in
  let x = Int64.abs x in
  let whole = Int64.div x unit_ in
  let frac = Int64.rem x unit_ in
  if Int64.equal frac 0L then Printf.sprintf "%s%Ld" sign whole
  else
    let s = Printf.sprintf "%08Ld" frac in
    let len = String.length s in
    let trim =
      let i = ref (len - 1) in
      while !i >= 0 && s.[!i] = '0' do
        decr i
      done;
      String.sub s 0 (!i + 1)
    in
    Printf.sprintf "%s%Ld.%s" sign whole trim

let of_string s =
  let s = String.trim s in
  if s = "" then invalid_arg "Decimal.of_string: empty";
  let neg_, rest =
    if s.[0] = '-' then (true, String.sub s 1 (String.length s - 1))
    else if s.[0] = '+' then (false, String.sub s 1 (String.length s - 1))
    else (false, s)
  in
  let whole, frac =
    match String.index_opt rest '.' with
    | None -> (rest, "")
    | Some i -> (String.sub rest 0 i, String.sub rest (i + 1) (String.length rest - i - 1))
  in
  let frac =
    if String.length frac > scale then String.sub frac 0 scale
    else frac ^ String.make (scale - String.length frac) '0'
  in
  let w = if whole = "" then 0L else Int64.of_string whole in
  let f = if frac = "" then 0L else Int64.of_string frac in
  let v = Int64.add (Int64.mul w unit_) f in
  if neg_ then Int64.neg v else v
