type t = { mutable current : int64 }

let make ?(initial = 0L) () = { current = initial }

let read c = c.current

let set c v = c.current <- v

let as_clock c = Clock.of_fn (fun () -> c.current)
