type ('key, 'value) t = {
  totals : ('key, 'value) Hashtbl.t;
  zero : 'value;
  add : 'value -> 'value -> 'value;
}

let create ~zero ~add : ('key, 'value) t = { totals = Hashtbl.create 16; zero; add }

let bump (s : ('key, 'value) t) ~key ~delta : 'value =
  let prev =
    match Hashtbl.find_opt s.totals key with
    | Some v -> v
    | None -> s.zero
  in
  let next = s.add prev delta in
  Hashtbl.replace s.totals key next;
  next
