open Core

(** Paginate bars across a date range. Brokers cap per-call bar
    count; we walk [to_ts] backwards in chunks until [from_ts] is
    covered or the broker stops making progress. The returned
    list is chronological with duplicates on chunk boundaries
    removed. *)
let paginate_bars ~(fetch : from_ts:int64 -> to_ts:int64 -> Candle.t list) ~from_ts ~to_ts
    : Candle.t list =
  let batches = ref [] in
  let cur_to = ref to_ts in
  let max_iters = 200 in
  let iter = ref 0 in
  let continue = ref true in
  while !continue && !iter < max_iters do
    let batch = fetch ~from_ts ~to_ts:!cur_to in
    (match batch with
    | [] -> continue := false
    | c0 :: _ ->
        let oldest = c0.Candle.ts in
        batches := batch :: !batches;
        if Int64.compare oldest from_ts <= 0 then continue := false
        else if Int64.compare oldest !cur_to >= 0 then continue := false
        else cur_to := Int64.sub oldest 1L);
    incr iter
  done;
  let chrono = List.concat (List.rev !batches) in
  let seen = Hashtbl.create 4096 in
  List.filter
    (fun (c : Candle.t) ->
      if Hashtbl.mem seen c.ts then false
      else begin
        Hashtbl.add seen c.ts ();
        true
      end)
    chrono
