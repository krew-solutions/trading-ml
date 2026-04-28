(** Command handler for {!Release_command.t}.

    Single responsibility: invoke {!Account.Portfolio.try_release}
    on the shared portfolio ref, mutate it on success, and return
    the resulting domain event. Does not publish, does not touch
    integration events — that is the domain-event handler's job
    composed downstream by {!Release_command_workflow.execute}. *)

val handle :
  portfolio:Account.Portfolio.t ref ->
  Release_command.t ->
  (Account.Portfolio.reservation_released, Account.Portfolio.release_error) Rop.t
