module Order = Paper_broker.Order

type t = { table : (string, Order.t) Hashtbl.t; mutex : Mutex.t }

let create () = { table = Hashtbl.create 64; mutex = Mutex.create () }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let save t (order : Order.t) =
  with_lock t (fun () ->
      if Hashtbl.mem t.table order.id then `Already_exists
      else begin
        Hashtbl.replace t.table order.id order;
        `Ok
      end)

let find t ~id = with_lock t (fun () -> Hashtbl.find_opt t.table id)

let find_active t =
  with_lock t (fun () ->
      Hashtbl.fold
        (fun _ order acc -> if Order.is_terminal order then acc else order :: acc)
        t.table [])

let update t ~id ~f =
  with_lock t (fun () ->
      match Hashtbl.find_opt t.table id with
      | None -> `Not_found
      | Some current ->
          (match f current with
          | `Replace order -> Hashtbl.replace t.table id order
          | `Delete -> Hashtbl.remove t.table id);
          `Updated)

let update_by_placement_id t ~placement_id ~f =
  with_lock t (fun () ->
      let found =
        Hashtbl.fold
          (fun _ order acc ->
            match acc with
            | Some _ -> acc
            | None ->
                if
                  Order.Values.Placement_id.to_int order.Order.placement_id
                  = placement_id
                then Some order
                else None)
          t.table None
      in
      match found with
      | None -> `Not_found
      | Some current ->
          (match f current with
          | `Replace order -> Hashtbl.replace t.table current.id order
          | `Delete -> Hashtbl.remove t.table current.id);
          `Updated)

let length t = with_lock t (fun () -> Hashtbl.length t.table)
