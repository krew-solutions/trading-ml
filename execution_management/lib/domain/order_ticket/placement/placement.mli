(** Placement entity — a single broker-bound slice of an
    OrderTicket. One ticket fans out N placements according to its
    Strategy.

    In PR1 this module is a re-export skeleton: it surfaces the
    Placement-scoped Value Objects (Placement_id, Fill_record) that
    the Strategy abstraction's Input/Decision types reference. The
    entity body (status transitions, accumulated fill aggregation)
    lands in PR3 alongside the OrderTicket aggregate root. *)

module Values : module type of Values
