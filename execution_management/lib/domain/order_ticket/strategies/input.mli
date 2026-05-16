(** Strategy input event — the union of all stimuli a strategy
    can react to. The aggregate translates each domain event (clock
    tick, broker IE, future volume bar / price quote) into the
    corresponding [Input.t] and feeds it to the embedded strategy.

    PR1 lists the constructors needed by [Immediate] plus [Tick]
    (which Immediate ignores but every time-driven strategy will
    react to from PR2 onward). PR2 expands the union with
    [Volume_bar] and [Price_quote] when VWAP / POV / Implementation
    Shortfall land. The expansion point is deliberate — adding
    constructors to this union is the abstraction's "load-bearing"
    moment and is the exact spot the PR2 checkpoint inspects.

    Strategies are not required to handle every constructor;
    irrelevant ones return [Decision.empty] with the state
    unchanged. *)

type t =
  | Tick of { now : int64 }
  | Placement_acknowledged of { placement_id : Placement.Values.Placement_id.t }
  | Placement_filled of {
      placement_id : Placement.Values.Placement_id.t;
      fill : Placement.Values.Fill_record.t;
    }
  | Placement_rejected of {
      placement_id : Placement.Values.Placement_id.t;
      reason : string;
    }
  | Placement_unreachable of { placement_id : Placement.Values.Placement_id.t }
  | Placement_cancelled of { placement_id : Placement.Values.Placement_id.t }
