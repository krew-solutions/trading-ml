module Order = Paper_broker.Order

type cancel_error =
  | Order_not_found of int
  | Order_already_terminal of Order.Values.Order_status.t

let cancel_error_to_string = function
  | Order_not_found pid ->
      Printf.sprintf "no working order for placement_id %d" pid
  | Order_already_terminal s ->
      Printf.sprintf "order is already in terminal status %s"
        (Order.Values.Order_status.to_string s)

type handle_error = Cancel of cancel_error

type cancel_outcome = { order : Order.t; event : Order.Events.Order_cancelled.t }

module type Store = Paper_broker_store.Order_store.S

let handle
    (type store)
    ~(store : (module Store with type t = store))
    ~(store_handle : store)
    ~(now_ts : unit -> int64)
    (cmd : Cancel_pending_order_command.t) : (cancel_outcome, handle_error) Rop.t =
  let module S = (val store : Store with type t = store) in
  let outcome = ref None in
  let result =
    S.update_by_placement_id store_handle ~placement_id:cmd.placement_id
      ~f:(fun current ->
        match Order.cancel current ~cancelled_ts:(now_ts ()) with
        | Ok (order', event) ->
            outcome := Some (Ok { order = order'; event });
            `Replace order'
        | Error (Order.Order_already_terminal s) ->
            outcome := Some (Rop.fail (Cancel (Order_already_terminal s)));
            `Replace current)
  in
  match result with
  | `Not_found -> Rop.fail (Cancel (Order_not_found cmd.placement_id))
  | `Updated -> (
      match !outcome with
      | Some (Ok o) -> Rop.succeed o
      | Some (Error errs) -> Error errs
      | None ->
          invalid_arg "Cancel_pending_order_command_handler: store update did not run f")
