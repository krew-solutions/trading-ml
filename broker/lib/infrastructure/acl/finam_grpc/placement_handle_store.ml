type t = {
  forward : (int, string) Hashtbl.t;
  reverse : (string, int) Hashtbl.t;
  mutex : Mutex.t;
}

let create () =
  { forward = Hashtbl.create 64; reverse = Hashtbl.create 64; mutex = Mutex.create () }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let record t ~placement_id ~client_order_id =
  with_lock t (fun () ->
      if Hashtbl.mem t.forward placement_id then `Already_exists
      else begin
        Hashtbl.replace t.forward placement_id client_order_id;
        Hashtbl.replace t.reverse client_order_id placement_id;
        `Ok
      end)

let find_client_order_id t ~placement_id =
  with_lock t (fun () -> Hashtbl.find_opt t.forward placement_id)

let find_placement_id t ~client_order_id =
  with_lock t (fun () -> Hashtbl.find_opt t.reverse client_order_id)

let all t =
  with_lock t (fun () -> Hashtbl.fold (fun pid cid acc -> (pid, cid) :: acc) t.forward [])
