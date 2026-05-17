module Ot = Execution_management.Order_ticket

type t = {
  table : (int, Ot.t) Hashtbl.t;
  mutex : Mutex.t;
}

let create () = { table = Hashtbl.create 32; mutex = Mutex.create () }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let get t tid =
  let k = Ot.Values.Ticket_id.to_int tid in
  with_lock t (fun () -> Hashtbl.find_opt t.table k)

let put t ticket =
  let k = Ot.Values.Ticket_id.to_int (Ot.ticket_id ticket) in
  with_lock t (fun () -> Hashtbl.replace t.table k ticket)

let all_open t =
  with_lock t (fun () ->
      Hashtbl.fold
        (fun _ ticket acc ->
          if Ot.is_terminal ticket then acc else ticket :: acc)
        t.table [])

let active_count t = List.length (all_open t)
