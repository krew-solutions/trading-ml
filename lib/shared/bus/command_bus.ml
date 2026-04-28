type 'a t = {
  to_string : 'a -> string;
  of_string : string -> 'a;
  stream : string Eio.Stream.t;
  mutable handler : ('a -> unit) option;
  mutex : Eio.Mutex.t;
}

exception Already_registered

exception No_handler

let create (type a) ~sw ~(to_string : a -> string) ~(of_string : string -> a) () : a t =
  let stream = Eio.Stream.create 1024 in
  let t = { to_string; of_string; stream; handler = None; mutex = Eio.Mutex.create () } in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec loop () =
        let payload = Eio.Stream.take stream in
        (match try Ok (t.of_string payload) with e -> Error (Printexc.to_string e) with
        | Error reason ->
            Logs.warn (fun m -> m "command_bus: deserialization failed: %s" reason)
        | Ok cmd -> (
            let h = Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.handler) in
            match h with
            | None ->
                Logs.warn (fun m ->
                    m "command_bus: dropping command — no handler registered")
            | Some f -> (
                try f cmd
                with e ->
                  Logs.warn (fun m ->
                      m "command_bus: handler raised: %s" (Printexc.to_string e)))));
        loop ()
      in
      loop ());
  t

let register_handler t f =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match t.handler with
      | Some _ -> raise Already_registered
      | None -> t.handler <- Some f)

let send t cmd = Eio.Stream.add t.stream (t.to_string cmd)
