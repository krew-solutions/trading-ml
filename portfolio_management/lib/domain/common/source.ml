open Core

type t =
  | Alpha_view of Alpha_source_id.t
  | Pair_mean_reversion of Pair.t
  | Pair_kalman_mean_reversion of Pair.t

let to_string = function
  | Alpha_view id -> Printf.sprintf "alpha_view:%s" (Alpha_source_id.to_string id)
  | Pair_mean_reversion p ->
      Printf.sprintf "pair_mean_reversion:%s|%s"
        (Instrument.to_qualified (Pair.a p))
        (Instrument.to_qualified (Pair.b p))
  | Pair_kalman_mean_reversion p ->
      Printf.sprintf "pair_kalman_mean_reversion:%s|%s"
        (Instrument.to_qualified (Pair.a p))
        (Instrument.to_qualified (Pair.b p))

let equal a b =
  match (a, b) with
  | Alpha_view x, Alpha_view y -> Alpha_source_id.equal x y
  | Pair_mean_reversion p, Pair_mean_reversion q -> Pair.equal p q
  | Pair_kalman_mean_reversion p, Pair_kalman_mean_reversion q -> Pair.equal p q
  | Alpha_view _, _ | Pair_mean_reversion _, _ | Pair_kalman_mean_reversion _, _ -> false
