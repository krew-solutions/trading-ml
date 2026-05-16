(** In-memory {!Paper_broker_store.Order_store.S} implementation for
    sociable tests. Single-threaded; no locking — Alcotest runners
    are sequential. *)

module Order = Paper_broker.Order

type t = (string, Order.t) Hashtbl.t

let create () : t = Hashtbl.create 8

let save (t : t) (order : Order.t) =
  if Hashtbl.mem t order.id then `Already_exists
  else begin
    Hashtbl.replace t order.id order;
    `Ok
  end

let find (t : t) ~id : Order.t option = Hashtbl.find_opt t id

let find_active (t : t) : Order.t list =
  Hashtbl.fold
    (fun _ order acc -> if Order.is_terminal order then acc else order :: acc)
    t []

let update (t : t) ~id ~f =
  match Hashtbl.find_opt t id with
  | None -> `Not_found
  | Some current ->
      (match f current with
      | `Replace order -> Hashtbl.replace t id order
      | `Delete -> Hashtbl.remove t id);
      `Updated

let update_by_placement_id (t : t) ~placement_id ~f =
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
      t None
  in
  match found with
  | None -> `Not_found
  | Some current ->
      (match f current with
      | `Replace order -> Hashtbl.replace t current.id order
      | `Delete -> Hashtbl.remove t current.id);
      `Updated

let length (t : t) : int = Hashtbl.length t
