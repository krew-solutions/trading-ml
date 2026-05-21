module Ot = Execution_management.Order_ticket
module Side = Core.Side

include Order_ticket_view_model_t
include Order_ticket_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

let lifecycle_to_strings (l : Ot.lifecycle) : string * string option =
  match l with
  | Working _ -> ("WORKING", None)
  | Cancelling { reason; _ } ->
      ("CANCELLING", Some (Ot.Values.Cancel_reason.to_string reason))
  | Filled -> ("FILLED", None)
  | Cancelled reason -> ("CANCELLED", Some (Ot.Values.Cancel_reason.to_string reason))
  | Failed reason -> ("FAILED", Some reason)

let strategy_of_lifecycle (l : Ot.lifecycle) : Ot.Strategies.Strategy.t option =
  match l with
  | Working s | Cancelling { strategy = s; _ } -> Some s
  | Filled | Cancelled _ | Failed _ -> None

let of_domain (t : Ot.t) : t =
  let intent = Ot.intent t in
  let lifecycle, lifecycle_reason = lifecycle_to_strings (Ot.lifecycle t) in
  let strategy =
    match strategy_of_lifecycle (Ot.lifecycle t) with
    | Some s -> Strategy_status_view_model.of_domain s
    | None ->
        (* Terminal ticket: synthesise a complete-flag view from
           the directive tag — no strategy state left to read. *)
        let kind =
          match Ot.directive t with
          | Immediate -> "IMMEDIATE"
          | Twap _ -> "TWAP"
          | Vwap _ -> "VWAP"
          | Pov _ -> "POV"
          | Iceberg _ -> "ICEBERG"
          | Implementation_shortfall _ -> "IMPLEMENTATION_SHORTFALL"
        in
        { Strategy_status_view_model_t.kind; is_complete = true }
  in
  {
    ticket_id = Ot.Values.Ticket_id.to_int (Ot.ticket_id t);
    book_id = intent.book_id;
    instrument = Instrument_view_model.of_domain intent.instrument;
    side = Side.to_string intent.side;
    total_quantity = Decimal.to_string intent.total_quantity;
    directive = Execution_directive_view_model.of_domain (Ot.directive t);
    lifecycle;
    lifecycle_reason;
    strategy;
    progress = Progress_view_model.of_domain (Ot.progress t);
    placements = List.map Placement_view_model.of_domain (Ot.placements t);
  }
