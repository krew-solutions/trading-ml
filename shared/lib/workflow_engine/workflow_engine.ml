module Store = Store
module In_memory_store = In_memory_store

module type WORKFLOW = sig
  type state
  type event
  type command

  val name : string
  val correlation_of_event : event -> string
  val transition : state -> event -> state * command list
  val is_terminal : state -> bool
end

module Make (W : WORKFLOW) (S : Store.S) = struct
  type t = { store : W.state S.t; dispatch : W.command -> unit }

  let create ~store ~dispatch = { store; dispatch }

  let start t ~correlation_id state =
    match S.put t.store ~correlation_id state with
    | `Ok -> ()
    | `Already_exists ->
        invalid_arg
          (Printf.sprintf "Workflow_engine[%s].start: %s already active" W.name
             correlation_id)

  (** [W.transition] runs inside the store's atomic update; commands
      are stashed in a closure-captured ref and dispatched **after**
      [S.update] returns, so a re-entrant dispatch doesn't deadlock
      against the store's own serialisation primitive. *)
  let on_event t ev =
    let cid = W.correlation_of_event ev in
    let to_dispatch = ref [] in
    let result =
      S.update t.store ~correlation_id:cid ~f:(fun state ->
          let new_state, commands = W.transition state ev in
          to_dispatch := commands;
          if W.is_terminal new_state then `Delete else `Replace new_state)
    in
    match result with
    | `Not_found ->
        Log.debug "Workflow_engine[%s] drop event for unknown cid=%s" W.name cid
    | `Updated -> List.iter t.dispatch !to_dispatch

  let get t ~correlation_id = S.get t.store ~correlation_id
  let active_count t = S.length t.store
end
