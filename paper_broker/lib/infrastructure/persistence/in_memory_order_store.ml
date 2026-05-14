module Pending_order = Paper_broker_commands.Pending_order

type t = { table : (string, Pending_order.t) Hashtbl.t; mutex : Mutex.t }

let create () = { table = Hashtbl.create 64; mutex = Mutex.create () }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let save t (po : Pending_order.t) =
  let id = Pending_order.id po in
  with_lock t (fun () ->
      if Hashtbl.mem t.table id then `Already_exists
      else begin
        Hashtbl.replace t.table id po;
        `Ok
      end)

let find t ~id = with_lock t (fun () -> Hashtbl.find_opt t.table id)

let find_active t =
  with_lock t (fun () ->
      Hashtbl.fold
        (fun _ po acc -> if Pending_order.is_terminal po then acc else po :: acc)
        t.table [])

let update t ~id ~f =
  with_lock t (fun () ->
      match Hashtbl.find_opt t.table id with
      | None -> `Not_found
      | Some current ->
          (match f current with
          | `Replace po -> Hashtbl.replace t.table id po
          | `Delete -> Hashtbl.remove t.table id);
          `Updated)

let length t = with_lock t (fun () -> Hashtbl.length t.table)
