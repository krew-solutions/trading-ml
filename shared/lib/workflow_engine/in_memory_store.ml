type 'state t = { table : (string, 'state) Hashtbl.t; mutex : Mutex.t }

let create () = { table = Hashtbl.create 64; mutex = Mutex.create () }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let put t ~correlation_id state =
  with_lock t (fun () ->
      if Hashtbl.mem t.table correlation_id then `Already_exists
      else begin
        Hashtbl.replace t.table correlation_id state;
        `Ok
      end)

let get t ~correlation_id =
  with_lock t (fun () -> Hashtbl.find_opt t.table correlation_id)

let update t ~correlation_id ~f =
  with_lock t (fun () ->
      match Hashtbl.find_opt t.table correlation_id with
      | None -> `Not_found
      | Some state ->
          (match f state with
          | `Replace s' -> Hashtbl.replace t.table correlation_id s'
          | `Delete -> Hashtbl.remove t.table correlation_id);
          `Updated)

let length t = with_lock t (fun () -> Hashtbl.length t.table)
