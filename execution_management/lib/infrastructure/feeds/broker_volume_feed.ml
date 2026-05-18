module Vb = Execution_management.Order_ticket.Values.Volume_bar

type subscription = {
  id : int;
  key : string;
}

type entry = {
  sub : subscription;
  on_bar : Vb.t -> unit;
}

type t = {
  table : (string, entry list ref) Hashtbl.t;
  mutex : Mutex.t;
  mutable next_id : int;
}

let create () =
  { table = Hashtbl.create 32; mutex = Mutex.create (); next_id = 1 }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let key_of ~instrument ~timeframe =
  Core.Instrument.to_qualified instrument ^ "|" ^ timeframe

let subscribe t ~instrument ~timeframe ~on_bar =
  let key = key_of ~instrument ~timeframe in
  with_lock t (fun () ->
      let id = t.next_id in
      t.next_id <- id + 1;
      let sub = { id; key } in
      let bucket =
        match Hashtbl.find_opt t.table key with
        | Some b -> b
        | None ->
            let b = ref [] in
            Hashtbl.add t.table key b;
            b
      in
      bucket := { sub; on_bar } :: !bucket;
      sub)

let unsubscribe t (sub : subscription) =
  with_lock t (fun () ->
      match Hashtbl.find_opt t.table sub.key with
      | None -> ()
      | Some bucket ->
          bucket := List.filter (fun e -> e.sub.id <> sub.id) !bucket;
          if !bucket = [] then Hashtbl.remove t.table sub.key)

let deliver t ~instrument ~timeframe ~bar =
  let key = key_of ~instrument ~timeframe in
  let entries =
    with_lock t (fun () ->
        match Hashtbl.find_opt t.table key with
        | None -> []
        | Some bucket -> !bucket)
  in
  List.iter
    (fun e ->
      try e.on_bar bar with _ -> ())
    entries
