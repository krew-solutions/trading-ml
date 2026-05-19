(** ROP pipeline for {!Subscribe_book_to_alpha_command.t}.
    Thin wrapper around the handler; no additional downstream
    side effects today. *)

val execute :
  persist_subscription:
    (Portfolio_management.Common.Alpha_subscription.t -> unit) ->
  Subscribe_book_to_alpha_command.t ->
  (unit, Subscribe_book_to_alpha_command_handler.handle_error) Rop.t
