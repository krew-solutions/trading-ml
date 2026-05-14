let make () : Clock.t = Clock.of_fn (fun () -> Int64.of_float (Unix.gettimeofday ()))
