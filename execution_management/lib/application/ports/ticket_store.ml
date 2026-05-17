module type S = sig
  type t

  val get :
    t -> Execution_management.Order_ticket.Values.Ticket_id.t ->
    Execution_management.Order_ticket.t option

  val put : t -> Execution_management.Order_ticket.t -> unit
  val all_open : t -> Execution_management.Order_ticket.t list
  val active_count : t -> int
end
