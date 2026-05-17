(** Re-export module for Placement's Value Objects per ADR 0006.
    [Order_kind] and [Tif] describe the venue-facing shape of a
    single placement; they live at the Entity level (not the
    aggregate-root level) because they are properties of a
    Placement, not of the OrderTicket overall. *)

module Placement_id = Placement_id
module Fill_record = Fill_record
module Placement_status = Placement_status
module Order_kind = Order_kind
module Tif = Tif
