type t = { read : unit -> int64 }

let of_fn read = { read }

let now c = c.read ()
