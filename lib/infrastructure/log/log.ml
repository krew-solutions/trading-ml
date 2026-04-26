(** Printf-style wrappers over the [Logs] library.

    Callers write [Log.info "foo %s" x] instead of the closure-based
    [Logs.info (fun m -> m "foo %s" x)]. All messages go through the
    globally-configured [Logs] reporter, which the binary sets up at
    startup via {!setup}.

    This is the only module that mentions [Logs] — the rest of the
    codebase sees plain format-string functions. *)

let src = Logs.Src.create "trading" ~doc:"trading application"
module L = (val Logs.src_log src : Logs.LOG)

let debug fmt = Printf.ksprintf (fun msg -> L.debug (fun m -> m "%s" msg)) fmt

let info fmt = Printf.ksprintf (fun msg -> L.info (fun m -> m "%s" msg)) fmt

let warn fmt = Printf.ksprintf (fun msg -> L.warn (fun m -> m "%s" msg)) fmt

let error fmt = Printf.ksprintf (fun msg -> L.err (fun m -> m "%s" msg)) fmt

(** Initialise the [Logs] reporter. Call once from [main]. *)
let setup ?(level = Logs.Info) () =
  Logs.set_level (Some level);
  Logs.set_reporter (Logs_fmt.reporter ());
  Fmt_tty.setup_std_outputs ()
