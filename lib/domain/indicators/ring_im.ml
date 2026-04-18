(** List-backed immutable ring. Items stored newest-first — the
    head is the most recent push, the tail is the oldest. *)

type 'a t = {
  items : 'a list;
  size : int;
  capacity : int;
}

let create ~capacity _ = { items = []; size = 0; capacity }

(** Drop the last element of [l]. Assumes [l] non-empty. *)
let rec drop_last = function
  | [] | [_] -> []
  | x :: rest -> x :: drop_last rest

let push r x =
  if r.size < r.capacity then
    { r with items = x :: r.items; size = r.size + 1 }
  else
    { r with items = x :: drop_last r.items }

let is_full r = r.size = r.capacity
let size r = r.size
let capacity r = r.capacity

(** Chronological index [i=0] = oldest. With newest-first
    storage, position [i] in chronological order is position
    [size - 1 - i] in the list. *)
let get r i = List.nth r.items (r.size - 1 - i)

let oldest r =
  match r.items with
  | [] -> invalid_arg "Ring_im.oldest: empty"
  | _ -> List.nth r.items (r.size - 1)

let newest r =
  match r.items with
  | x :: _ -> x
  | [] -> invalid_arg "Ring_im.newest: empty"

(** Fold oldest → newest. Internal list is newest-first, so we
    process it via [List.fold_right] which visits right-to-left
    and applies [f] in that order (oldest is rightmost). *)
let fold r init f =
  List.fold_right (fun x acc -> f acc x) r.items init

let iter r f =
  (* Build reversed list once and iterate — cheaper than
     repeated List.nth calls, clearer than fold with unit. *)
  List.iter f (List.rev r.items)
