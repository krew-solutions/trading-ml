(** Aggregate root for the OrderTicket — the EMS-side aggregate
    that owns a trader's execution intent through its slicing
    lifecycle.

    PR1 is a skeleton: the aggregate type and operations land in
    PR3. This module exists today to make the nested namespaces
    ([Values], [Placement], [Strategies]) externally accessible
    per ADR 0006's explicit-re-export rule — without this file,
    [Execution_management.Order_ticket.Strategies.Strategy] would
    not resolve from outside the library. *)

module Values : module type of Values
module Placement : module type of Placement
module Strategies : module type of Strategies
