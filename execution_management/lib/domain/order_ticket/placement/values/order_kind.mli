(** Order kind — what to ask the venue for, parameterised by any
    prices the kind requires. Domain-local to execution_management;
    broker BC defines a sibling on its own side of the ACL.

    [Market] takes the best available; [Limit] caps the price;
    [Stop] activates on a trigger; [Stop_limit] combines both. *)

type t =
  | Market
  | Limit of { price : Decimal.t }
  | Stop of { stop_price : Decimal.t }
  | Stop_limit of { stop_price : Decimal.t; limit_price : Decimal.t }
