(** Thin stderr logger — no external deps, single format:
      [YYYY-MM-DD HH:MM:SS.mmm] [level] message
    Kept tiny on purpose: one format, one sink, one mutex. A full Logs
    pipeline can replace this module without changing callers. *)

type level = Debug | Info | Warn | Error

let level_label = function
  | Debug -> "DEBUG" | Info -> "INFO " | Warn -> "WARN " | Error -> "ERROR"

(** Stderr writes from multiple fibers would otherwise interleave. *)
let mutex = Mutex.create ()

(** Format [now] as local time with millisecond precision. *)
let ts_now () =
  let t = Unix.gettimeofday () in
  let tm = Unix.localtime t in
  let ms = int_of_float ((t -. floor t) *. 1000.) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d.%03d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec ms

let log level fmt =
  Printf.ksprintf (fun msg ->
    Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock mutex) (fun () ->
      Printf.eprintf "[%s] [%s] %s\n%!"
        (ts_now ()) (level_label level) msg)) fmt

let debug fmt = log Debug fmt
let info  fmt = log Info  fmt
let warn  fmt = log Warn  fmt
let error fmt = log Error fmt
