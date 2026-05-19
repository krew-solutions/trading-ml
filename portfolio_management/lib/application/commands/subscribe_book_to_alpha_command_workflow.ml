let execute ~persist_subscription (cmd : Subscribe_book_to_alpha_command.t) :
    (unit, Subscribe_book_to_alpha_command_handler.handle_error) Rop.t =
  Subscribe_book_to_alpha_command_handler.handle ~persist_subscription cmd
