open Core

(* Re-exports define the aggregate's public surface. dune's
   `(include_subdirs qualified)` collapses peer sub-directories into
   this file (matching the directory name), so they reach the outside
   only through these explicit aliases. *)
module Events = Events

(* Local shortcut. *)
module Target_set = Events.Target_set

type t = {
  book_id : Shared.Book_id.t;
  positions : Shared.Target_position.t list;
      (* invariants:
         - sorted by Instrument.compare on [instrument];
         - no duplicate [instrument] entries;
         - no entry with [target_qty = 0] (zeros are pruned). *)
}

let empty book_id = { book_id; positions = [] }

let book_id p = p.book_id

let positions p = p.positions

let target_for p instrument =
  match
    List.find_opt
      (fun (tp : Shared.Target_position.t) -> Instrument.equal tp.instrument instrument)
      p.positions
  with
  | Some tp -> tp.target_qty
  | None -> Decimal.zero

type apply_error =
  | Book_id_mismatch of {
      aggregate_book : Shared.Book_id.t;
      proposal_book : Shared.Book_id.t;
    }
  | Position_book_id_mismatch of {
      proposal_book : Shared.Book_id.t;
      position_instrument : Instrument.t;
      position_book : Shared.Book_id.t;
    }

(* Insert / overwrite [tp] into [positions]. Maintains sort order and
   the no-zero invariant. *)
let upsert positions (tp : Shared.Target_position.t) =
  let zero_qty = Decimal.is_zero tp.target_qty in
  let rec go acc = function
    | [] -> if zero_qty then List.rev acc else List.rev_append acc [ tp ]
    | (cur : Shared.Target_position.t) :: rest ->
        let c = Instrument.compare cur.instrument tp.instrument in
        if c = 0 then
          (* same instrument: overwrite (or prune on zero) *)
          if zero_qty then List.rev_append acc rest else List.rev_append acc (tp :: rest)
        else if c > 0 then
          (* insertion point preserves sort order *)
          if zero_qty then List.rev_append acc (cur :: rest)
          else List.rev_append acc (tp :: cur :: rest)
        else go (cur :: acc) rest
  in
  go [] positions

(* Compute the per-instrument deltas a proposal will cause when applied
   to the current positions list. Used to populate Target_set.changed. *)
let compute_changes ~previous (proposal : Shared.Target_proposal.t) :
    Target_set.change list =
  List.filter_map
    (fun (tp : Shared.Target_position.t) ->
      let prev =
        match
          List.find_opt
            (fun (cur : Shared.Target_position.t) ->
              Instrument.equal cur.instrument tp.instrument)
            previous
        with
        | Some cur -> cur.target_qty
        | None -> Decimal.zero
      in
      if Decimal.equal prev tp.target_qty then None
      else
        Some
          ({ instrument = tp.instrument; previous_qty = prev; new_qty = tp.target_qty }
            : Target_set.change))
    proposal.positions

let apply_proposal (p : t) (proposal : Shared.Target_proposal.t) :
    (t * Target_set.t, apply_error) result =
  if not (Shared.Book_id.equal p.book_id proposal.book_id) then
    Error
      (Book_id_mismatch { aggregate_book = p.book_id; proposal_book = proposal.book_id })
  else
    let mismatch =
      List.find_opt
        (fun (tp : Shared.Target_position.t) ->
          not (Shared.Book_id.equal tp.book_id proposal.book_id))
        proposal.positions
    in
    match mismatch with
    | Some (tp : Shared.Target_position.t) ->
        Error
          (Position_book_id_mismatch
             {
               proposal_book = proposal.book_id;
               position_instrument = tp.instrument;
               position_book = tp.book_id;
             })
    | None ->
        let changed = compute_changes ~previous:p.positions proposal in
        let positions' =
          List.fold_left (fun acc tp -> upsert acc tp) p.positions proposal.positions
        in
        let p' = { p with positions = positions' } in
        let event : Target_set.t =
          {
            book_id = p.book_id;
            source = proposal.source;
            proposed_at = proposal.proposed_at;
            changed;
          }
        in
        Ok (p', event)
