(** Tiny fixed-capacity ring buffer for O(1) windowed aggregates. *)

type 'a t = {
  buf : 'a array;
  mutable head : int;      (* next write position *)
  mutable size : int;
  capacity : int;
}

let create ~capacity default =
  { buf = Array.make capacity default; head = 0; size = 0; capacity }

let push r x =
  r.buf.(r.head) <- x;
  r.head <- (r.head + 1) mod r.capacity;
  if r.size < r.capacity then r.size <- r.size + 1

let is_full r = r.size = r.capacity
let size r = r.size
let capacity r = r.capacity

let get r i =
  (* i=0 → oldest element *)
  let start = if r.size < r.capacity then 0 else r.head in
  r.buf.((start + i) mod r.capacity)

let oldest r = get r 0
let newest r = get r (r.size - 1)

let fold r init f =
  let acc = ref init in
  for i = 0 to r.size - 1 do acc := f !acc (get r i) done;
  !acc

let iter r f = for i = 0 to r.size - 1 do f (get r i) done

let copy r = { r with buf = Array.copy r.buf }
