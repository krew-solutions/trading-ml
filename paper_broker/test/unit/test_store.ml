(** In-memory {!Order_store.S} implementation for sociable tests.
    Single-threaded; no locking — Alcotest runners are sequential. *)

module Pending_order = Paper_broker_commands.Pending_order

type t = (string, Pending_order.t) Hashtbl.t

let create () : t = Hashtbl.create 8

let save (t : t) (po : Pending_order.t) =
  let id = Pending_order.id po in
  if Hashtbl.mem t id then `Already_exists
  else begin
    Hashtbl.replace t id po;
    `Ok
  end

let find (t : t) ~id : Pending_order.t option = Hashtbl.find_opt t id

let find_active (t : t) : Pending_order.t list =
  Hashtbl.fold
    (fun _ po acc -> if Pending_order.is_terminal po then acc else po :: acc)
    t []

let update (t : t) ~id ~f =
  match Hashtbl.find_opt t id with
  | None -> `Not_found
  | Some current ->
      (match f current with
      | `Replace po -> Hashtbl.replace t id po
      | `Delete -> Hashtbl.remove t id);
      `Updated

let length (t : t) : int = Hashtbl.length t
