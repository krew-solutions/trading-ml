(** Eio runtime driver for an {!H2}/gluten protocol over an arbitrary
    {!Eio.Flow.two_way}.

    {b Why this exists.} [grpc-eio] (the obvious choice) does not build against
    the [h2 0.13] that ocaml 5.x + [eio 1.x] force, and the maintained
    [gluten-eio]/[h2-eio] client entry points constrain their socket argument to
    [_ Eio.Net.stream_socket]. A TLS flow ([Tls_eio.client_of_flow], required to
    reach Finam's gRPC endpoint on :443) is an [Eio.Flow.two_way] but {e not} a
    [stream_socket] — it carries no [`Socket] capability — so it cannot be
    handed to those entry points, even though the gluten IO loop only ever uses
    plain {!Eio.Flow} reads/writes/shutdown on it.

    This module re-expresses gluten-eio's client IO loop with the socket typed
    (by inference) as [_ Eio.Flow.two_way], which is the looser type the loop has
    always actually needed. That lets the gRPC channel run HTTP/2 directly over a
    [Tls_eio] flow with no [stream_socket] coercion. The protocol state machine
    ([Gluten.Client], [H2.Client_connection]) is used unchanged.

    Adapted from gluten-eio (c) 2022 António Nuno Monteiro, BSD-3-Clause. *)

open Eio.Std
module Buffer = Gluten.Buffer

module IO_loop = struct
  let writev socket iovecs =
    let lenv, cstructs =
      List.fold_left_map
        (fun acc { Faraday.buffer; off; len } ->
          (acc + len, Cstruct.of_bigarray buffer ~off ~len))
        0 iovecs
    in
    match Eio.Flow.write socket cstructs with
    | () -> `Ok lenv
    | exception End_of_file -> `Closed

  let read_once flow buffer =
    let p, u = Promise.create () in
    Buffer.put
      ~f:(fun buf ~off ~len k ->
        let cstruct = Cstruct.of_bigarray buf ~off ~len in
        k (Eio.Flow.single_read flow cstruct))
      buffer (Promise.resolve u);
    Promise.await p

  let read flow buffer =
    match read_once flow buffer with
    | r -> r
    | exception
        ( Unix.Unix_error (ENOTCONN, _, _)
        | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (ENOTCONN, _, _)), _)
        | Eio.Io (Eio.Net.E (Connection_reset _), _) ) -> raise End_of_file

  let shutdown flow cmd =
    try Eio.Flow.shutdown flow cmd
    with
    | Unix.Unix_error (ENOTCONN, _, _)
    | Eio.Io (Eio.Exn.X (Eio_unix.Unix_error (ENOTCONN, _, _)), _)
    ->
      ()

  let start : type t.
      (module Gluten.RUNTIME with type t = t) ->
      read_buffer_size:int ->
      read_closed:unit Promise.t * unit Promise.u ->
      t ->
      _ Eio.Flow.two_way ->
      unit =
   fun (module Runtime) ~read_buffer_size ~read_closed t socket ->
    let read_closed, resolve_read_closed = read_closed in
    let write_closed = ref false in
    let read_buffer = Buffer.create read_buffer_size in
    let rec read_loop =
      let read socket read_buffer =
        Fiber.first
          (fun () -> read socket read_buffer)
          (fun () ->
            Promise.await read_closed;
            raise End_of_file)
      in
      fun () ->
        let rec read_loop_step () =
          match Runtime.next_read_operation t with
          | `Read ->
              (match read socket read_buffer with
              | _n ->
                  let (_ : int) =
                    Buffer.get read_buffer ~f:(fun buf ~off ~len ->
                        Runtime.read t buf ~off ~len)
                  in
                  ()
              | exception End_of_file ->
                  let (_ : int) =
                    Buffer.get read_buffer ~f:(fun buf ~off ~len ->
                        Runtime.read_eof t buf ~off ~len)
                  in
                  ());
              read_loop_step ()
          | `Yield ->
              let p, u = Promise.create () in
              Runtime.yield_reader t (fun () -> Promise.resolve u ());
              Promise.await p;
              read_loop ()
          | `Close -> (
              match Promise.is_resolved read_closed with
              | true -> ()
              | false -> (
                  match read socket read_buffer with
                  | _n -> assert false
                  | exception (End_of_file as exn) -> (
                      shutdown socket `Receive;
                      Promise.resolve resolve_read_closed ();
                      match !write_closed with
                      | true -> ()
                      | false -> Runtime.report_exn t exn)))
        in
        match read_loop_step () with
        | () -> ()
        | exception exn -> Runtime.report_exn t exn
    in
    let rec write_loop () =
      let rec write_loop_step () =
        match Runtime.next_write_operation t with
        | `Write io_vectors ->
            let write_result = writev socket io_vectors in
            Runtime.report_write_result t write_result;
            write_loop_step ()
        | `Yield ->
            let p, u = Promise.create () in
            Runtime.yield_writer t (fun () -> Promise.resolve u ());
            Promise.await p;
            write_loop ()
        | `Close _ ->
            write_closed := true;
            shutdown socket `Send
      in
      match write_loop_step () with
      | () -> ()
      | exception exn -> Runtime.report_exn t exn
    in
    Fiber.both read_loop write_loop
end

module Client = struct
  type t = {
    connection : Gluten.Client.t;
    shutdown_reader : unit -> unit;
    shutdown_complete : unit Promise.t;
  }

  let create ~sw ~read_buffer_size ~protocol t socket =
    let connection = Gluten.Client.create ~protocol t in
    let shutdown_p, shutdown_u = Promise.create () in
    let read_closed = Promise.create () in
    Fiber.fork ~sw (fun () ->
        Fun.protect ~finally:(Promise.resolve shutdown_u) (fun () ->
            Switch.run (fun sw ->
                Fiber.fork ~sw (fun () ->
                    IO_loop.start
                      (module Gluten.Client)
                      ~read_closed ~read_buffer_size connection socket))));
    {
      connection;
      shutdown_reader =
        (fun () ->
          let cancel_reader, resolve_cancel_reader = read_closed in
          if not (Promise.is_resolved cancel_reader) then
            Promise.resolve resolve_cancel_reader ());
      shutdown_complete = shutdown_p;
    }

  let shutdown t =
    t.shutdown_reader ();
    Gluten.Client.shutdown t.connection;
    t.shutdown_complete

  let is_closed t = Gluten.Client.is_closed t.connection
end
