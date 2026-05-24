(** PM inbound HTTP routes — admin-side configuration surface.

    Routes:
      POST /api/portfolio_management/risk_configs
        — apply a {!Configure_risk_command.t} to the per-book
          {!Risk_config} registry.
      POST /api/portfolio_management/alpha_subscriptions
        — register a {!Common.Alpha_subscription.t} for an
          [(alpha_source_id, instrument, book_id)] triplet.
      POST /api/portfolio_management/pair_mr_policies
        — define a {!Pair_mean_reversion} policy state for a
          book via {!Define_pair_mr_command.t}.
      POST /api/portfolio_management/pair_kalman_mr_policies
        — define a {!Pair_kalman_mean_reversion} policy state
          for a book via {!Define_pair_kalman_mr_command.t}.

    Synchronous: 200 OK on success, 400 Bad Request with a
    structured error list on Rop validation failure.

    Trading-side workflows reach this BC over the in-memory bus
    (signal_detected, bar_updated, reservation_filled);
    configuration commands are admin-only, low-frequency, need
    immediate validation feedback, and have no downstream
    side-effects beyond registry mutation — so direct REST is
    the right transport, not a bus-front-door. *)

val make_handler :
  configure_risk:
    (Portfolio_management_commands.Configure_risk_command.t ->
    ( unit,
      Portfolio_management_commands.Configure_risk_command_handler.handle_error )
    Rop.t) ->
  subscribe_book_to_alpha:
    (Portfolio_management_commands.Subscribe_book_to_alpha_command.t ->
    ( unit,
      Portfolio_management_commands.Subscribe_book_to_alpha_command_handler.handle_error
    )
    Rop.t) ->
  define_pair_mr:
    (Portfolio_management_commands.Define_pair_mr_command.t ->
    ( unit,
      Portfolio_management_commands.Define_pair_mr_command_handler.handle_error )
    Rop.t) ->
  define_pair_kalman_mr:
    (Portfolio_management_commands.Define_pair_kalman_mr_command.t ->
    ( unit,
      Portfolio_management_commands.Define_pair_kalman_mr_command_handler.handle_error )
    Rop.t) ->
  Inbound_http.Route.handler
