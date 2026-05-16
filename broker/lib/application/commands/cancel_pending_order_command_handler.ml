type resolution_error = Placement_not_found of int

let resolution_error_to_string = function
  | Placement_not_found pid ->
      Printf.sprintf "no placement recorded under placement_id %d" pid

type broker_outcome =
  | Cancel_confirmed of { cancelled_ts : int64 }
  | Cancel_pending of { cancelled_ts : int64 }
  | Cancel_refused of { reason : string }
  | Unreachable of { reason : string }

type handle_error = Resolution of resolution_error

let classify ~cancelled_ts ~status : broker_outcome =
  match status with
  | "CANCELLED" -> Cancel_confirmed { cancelled_ts }
  | "PENDING_CANCEL" -> Cancel_pending { cancelled_ts }
  | other -> Cancel_refused { reason = other }

let handle
    ~(broker : Broker.client)
    ~(now_ts : unit -> int64)
    (cmd : Cancel_pending_order_command.t) : (broker_outcome, handle_error) Rop.t =
  let cancelled_ts = now_ts () in
  match
    try Ok (Broker.cancel_order_by_placement_id broker ~placement_id:cmd.placement_id)
    with e -> Error (Printexc.to_string e)
  with
  | Error reason -> Rop.succeed (Unreachable { reason })
  | Ok None -> Rop.fail (Resolution (Placement_not_found cmd.placement_id))
  | Ok (Some (vm : Order_view_model.t)) ->
      Rop.succeed (classify ~cancelled_ts ~status:vm.status)
