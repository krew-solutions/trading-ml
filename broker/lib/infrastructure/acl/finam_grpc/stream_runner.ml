(** Reconnecting runner for one gRPC server-stream.

    A gRPC server-stream is a single long-lived call that returns when the
    server half-closes or the connection drops. This runner forks a fiber that
    (re)issues the call, so a dropped subscription transparently re-subscribes —
    the streaming analog of {!Websocket.Resilient} for the REST/WS sibling, but
    far simpler because gRPC owns the multiplexed transport and there is no
    REST-poll fallback to interleave.

    [run] is the blocking subscribe call (e.g. {!Client.subscribe_bars}); it is
    re-invoked after [backoff] seconds whenever it returns or raises, until
    {!stop}. Dedup of any replayed prefix on re-subscribe is the caller's
    concern (it wires a {!Acl_common.Stream_dedup} / high-water into [run]'s
    per-message callback), exactly as the supervised REST/WS paths do. *)

open Eio.Std

type t = {
  mutable stopped : bool;
  stop_p : unit Promise.t;
  resolve_stop : unit Promise.u;
}

let start ~sw ~env ~label ?(backoff = 3.0) ~run () : t =
  let stop_p, resolve_stop = Promise.create () in
  let t = { stopped = false; stop_p; resolve_stop } in
  let clock = Eio.Stdenv.clock env in
  Fiber.fork ~sw (fun () ->
      let rec loop () =
        if t.stopped then ()
        else begin
          (try
             (* Race the stream against the stop signal: stopping cancels the
                in-flight [run]. *)
             Fiber.first (fun () -> Promise.await t.stop_p) (fun () -> run ())
           with e -> Log.warn "[finam-grpc stream] %s: %s" label (Printexc.to_string e));
          if not t.stopped then begin
            Eio.Time.sleep clock backoff;
            loop ()
          end
        end
      in
      loop ());
  t

let stop t =
  if not t.stopped then begin
    t.stopped <- true;
    if not (Promise.is_resolved t.stop_p) then Promise.resolve t.resolve_stop ()
  end
