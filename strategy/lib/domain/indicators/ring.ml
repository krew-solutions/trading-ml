(** Tiny fixed-capacity ring buffer for O(1) windowed aggregates.

    Internal representation keeps a mutable array for contiguous
    memory, but that mutation never leaks to callers — [push]
    allocates a fresh array, writes to it, and returns a new
    ring value. The public API therefore enforces persistence by
    type: you can't call [push] without capturing the returned
    ring. *)

type 'a t = { buf : 'a array; head : int; size : int; capacity : int }

let create ~capacity default =
  { buf = Array.make capacity default; head = 0; size = 0; capacity }

let push r x =
  let buf' = Array.copy r.buf in
  buf'.(r.head) <- x;
  {
    r with
    buf = buf';
    head = (r.head + 1) mod r.capacity;
    size = (if r.size < r.capacity then r.size + 1 else r.size);
  }

let is_full r = r.size = r.capacity
let size r = r.size
let capacity r = r.capacity

let get r i =
  (* i=0 → oldest. Start index is [head] when full (wrapping),
     else 0 when still filling up. *)
  let start = if r.size < r.capacity then 0 else r.head in
  r.buf.((start + i) mod r.capacity)

let oldest r = get r 0
let newest r = get r (r.size - 1)

let fold r init f =
  let acc = ref init in
  for i = 0 to r.size - 1 do
    acc := f !acc (get r i)
  done;
  !acc

let iter r f =
  for i = 0 to r.size - 1 do
    f (get r i)
  done
