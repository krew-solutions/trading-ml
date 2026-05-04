module Direction = struct
  type t = Flat | Long_spread | Short_spread

  let equal a b =
    match (a, b) with
    | Flat, Flat | Long_spread, Long_spread | Short_spread, Short_spread -> true
    | _ -> false
end

(* Fixed-size circular buffer of doubles. *)
type ring = { capacity : int; data : float array; next : int; count : int }

let ring_create capacity =
  { capacity; data = Array.make capacity 0.0; next = 0; count = 0 }

let ring_push r v =
  let data' = Array.copy r.data in
  data'.(r.next) <- v;
  let next' = (r.next + 1) mod r.capacity in
  let count' = if r.count < r.capacity then r.count + 1 else r.capacity in
  { r with data = data'; next = next'; count = count' }

let ring_full r = r.count >= r.capacity

(* Population mean and stdev over the populated portion of the ring. *)
let ring_stats r =
  let n = float_of_int r.count in
  if r.count = 0 then (0.0, 0.0)
  else
    let sum = ref 0.0 in
    for i = 0 to r.count - 1 do
      sum := !sum +. r.data.(i)
    done;
    let mean = !sum /. n in
    let sq = ref 0.0 in
    for i = 0 to r.count - 1 do
      let d = r.data.(i) -. mean in
      sq := !sq +. (d *. d)
    done;
    let variance = !sq /. n in
    (mean, sqrt variance)

let ring_last r =
  if r.count = 0 then None
  else
    let idx = (r.next - 1 + r.capacity) mod r.capacity in
    Some r.data.(idx)

type t = {
  config : Pair_mr_config.t;
  spreads : ring;
  direction : Direction.t;
  last_a_log_close : float option;
  last_b_log_close : float option;
}

let init (config : Pair_mr_config.t) =
  {
    config;
    spreads = ring_create config.window;
    direction = Direction.Flat;
    last_a_log_close = None;
    last_b_log_close = None;
  }

let config s = s.config
let direction s = s.direction
let sample_count s = s.spreads.count

let record_log_close s ~leg ~log_close =
  let s' =
    match leg with
    | `A -> { s with last_a_log_close = Some log_close }
    | `B -> { s with last_b_log_close = Some log_close }
  in
  match (s'.last_a_log_close, s'.last_b_log_close) with
  | Some la, Some lb ->
      let beta = Decimal.to_float (Common.Hedge_ratio.to_decimal s'.config.hedge_ratio) in
      let spread = la -. (beta *. lb) in
      { s' with spreads = ring_push s'.spreads spread }
  | _ -> s'

let current_z s =
  if not (ring_full s.spreads) then None
  else
    let mean, sd = ring_stats s.spreads in
    match ring_last s.spreads with
    | None -> None
    | Some last -> if sd = 0.0 then None else Some ((last -. mean) /. sd)

let with_direction s direction = { s with direction }

let last_log_close s ~leg =
  match leg with
  | `A -> s.last_a_log_close
  | `B -> s.last_b_log_close
