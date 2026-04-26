type 'a t = 'a Seq.t

(* --- Construction --- *)

let empty = Seq.empty
let cons = Seq.cons
let of_list = List.to_seq
let unfold = Seq.unfold

(* --- Transforms --- *)

let map = Seq.map
let filter = Seq.filter
let filter_map = Seq.filter_map
let take = Seq.take
let zip = Seq.zip

(** [scan_map] isn't in stdlib — {!Seq.scan} emits accumulator
    snapshots, not per-step outputs. We need both: the state flows
    forward, a distinct [out] value is produced each step. Single
    recursive definition; the closure captures [step] and recurses
    lazily on each forced node. *)
let rec scan_map (state : 'state) step seq () : 'b Seq.node =
  match seq () with
  | Seq.Nil -> Seq.Nil
  | Seq.Cons (x, rest) ->
      let state', y = step state x in
      Seq.Cons (y, scan_map state' step rest)

let rec scan_filter_map (state : 'state) step seq () : 'b Seq.node =
  match seq () with
  | Seq.Nil -> Seq.Nil
  | Seq.Cons (x, rest) -> (
      let state', y_opt = step state x in
      match y_opt with
      | Some y -> Seq.Cons (y, scan_filter_map state' step rest)
      | None -> scan_filter_map state' step rest ())

(* --- Consumption --- *)

let to_list = List.of_seq
let iter = Seq.iter
let fold_left = Seq.fold_left
