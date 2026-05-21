type ('key, 'value) t = {
  state : ('key, int64 option ref * 'value list ref) Hashtbl.t;
  equal_value : 'value -> 'value -> bool;
}

let create ~equal_value : ('key, 'value) t = { state = Hashtbl.create 16; equal_value }

let should_accept (s : ('key, 'value) t) ~key ~ts ~value : bool =
  let tail_ts, sent_at_tail =
    match Hashtbl.find_opt s.state key with
    | Some pair -> pair
    | None ->
        let pair = (ref None, ref []) in
        Hashtbl.add s.state key pair;
        pair
  in
  match !tail_ts with
  | None ->
      tail_ts := Some ts;
      sent_at_tail := [ value ];
      true
  | Some t when Int64.compare ts t < 0 -> false
  | Some t when Int64.compare ts t > 0 ->
      tail_ts := Some ts;
      sent_at_tail := [ value ];
      true
  | Some _ ->
      if List.exists (s.equal_value value) !sent_at_tail then false
      else begin
        sent_at_tail := value :: !sent_at_tail;
        true
      end
