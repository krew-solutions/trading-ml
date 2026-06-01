module Footprint_completed_ie =
  Order_flow_integration_events.Footprint_completed_integration_event

module Instrument_vm = Order_flow_view_models.Instrument_view_model

(* Per key a most-recent-first list capped at [cap]; the head is the
   latest seal. Lists (not arrays) keep [record] simple — caps here are
   small (a few hundred) and the query reverses once. *)
type t = { cap : int; mutable rings : (string * Footprint_completed_ie.t list) list }

let create ?(cap = 500) () = { cap; rings = [] }

(* Match Instrument.to_qualified: TICKER@MIC, with /BOARD appended when
   present, so the key agrees with how callers spell the symbol on the
   wire; suffix the boundary token to scope per (instrument, boundary). *)
let qualified (i : Instrument_vm.t) =
  i.Instrument_vm.ticker ^ "@" ^ i.Instrument_vm.venue
  ^
  match i.Instrument_vm.board with
  | Some b -> "/" ^ b
  | None -> ""

let key (ie : Footprint_completed_ie.t) =
  qualified ie.Footprint_completed_ie.instrument ^ "|" ^ ie.timeframe

let take n xs =
  let rec go n = function
    | x :: tl when n > 0 -> x :: go (n - 1) tl
    | _ -> []
  in
  if n <= 0 then [] else go n xs

let record (t : t) (ie : Footprint_completed_ie.t) : unit =
  let k = key ie in
  let cur = try List.assoc k t.rings with Not_found -> [] in
  let cur =
    (* Idempotent head replace: a redelivery of the latest open_ts
       overwrites rather than doubles. *)
    match cur with
    | hd :: tl when hd.Footprint_completed_ie.open_ts = ie.open_ts -> tl
    | _ -> cur
  in
  let updated = take t.cap (ie :: cur) in
  t.rings <- (k, updated) :: List.remove_assoc k t.rings

let recent (t : t) ~symbol ~timeframe ~n : Footprint_completed_ie.t list =
  let k = symbol ^ "|" ^ timeframe in
  match List.assoc_opt k t.rings with
  | None -> []
  | Some ring -> List.rev (take n ring)
(* most-recent-first ring -> oldest-first, last n *)
