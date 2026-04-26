type event =
  | Amount_reserved of Engine.Portfolio.amount_reserved
  | Order_forwarded of Domain_event_handlers.Forward_order_to_broker.order_forwarded
  | Forward_rejected of Domain_event_handlers.Forward_order_to_broker.forward_rejection
  | Reservation_released of Engine.Portfolio.reservation_released

type error =
  | Validation_errors of Commands.Place_order_command.validation_error list
  | Reservation_rejected of Engine.Portfolio.reservation_error

(** Peel the first element off a Rop-style non-empty error list.
    Used at boundary points where a step is known to produce at
    most one error (reserve, forward) — the singleton-list
    wrapper is a Rop convention, not a multi-error accumulation. *)
let first : 'e list -> 'e = function
  | e :: _ -> e
  | [] -> failwith "place_order_workflow: invariant — Rop error list is non-empty"

let run
    ~(portfolio : Engine.Portfolio.t)
    ~(market_price : Core.Decimal.t)
    ~(slippage_buffer : float)
    ~(fee_rate : float)
    ~(next_reservation_id : unit -> int)
    ~(place_order : Domain_event_handlers.Forward_order_to_broker.place_order_port)
    (cmd : Commands.Place_order_command.t) :
    (Engine.Portfolio.t * event list, error) result =
  let ( let* ) = Result.bind in
  (* Parse + validate the command — accumulating errors across
     all fields. *)
  let* u =
    Commands.Place_order_command.to_unvalidated cmd
    |> Result.map_error (fun errs -> Validation_errors errs)
  in
  (* Reserve in local portfolio — aggregate invariant check. *)
  let* portfolio', reserved =
    Commands.Place_order_command.reserve ~portfolio ~market_price ~slippage_buffer
      ~fee_rate ~next_reservation_id u
    |> Result.map_error (fun errs -> Reservation_rejected (first errs))
  in
  let events_so_far = [ Amount_reserved reserved ] in
  (* Forward to broker. From this point on, every outcome is an
     event — including broker rejection. The command "happened"
     even if the broker said no, because we earmarked cash. *)
  match
    Domain_event_handlers.Forward_order_to_broker.handle ~place_order ~kind:u.kind
      ~tif:u.tif ~client_order_id:u.client_order_id reserved
  with
  | Ok forwarded -> Ok (portfolio', events_so_far @ [ Order_forwarded forwarded ])
  | Error rejs -> (
      let rejection = first rejs in
      let events_with_rejection = events_so_far @ [ Forward_rejected rejection ] in
      (* Branch: release the earmark. Handler returns a Rop.t;
       Reservation_not_found is unreachable here (we just
       created the reservation in step 1 with this id) — fall
       back to current portfolio state if it ever happens. *)
      match
        Domain_event_handlers.Release_reservation_on_broker_rejection.handle
          ~portfolio:portfolio' rejection
      with
      | Ok (portfolio'', released) ->
          Ok (portfolio'', events_with_rejection @ [ Reservation_released released ])
      | Error _ -> Ok (portfolio', events_with_rejection))
