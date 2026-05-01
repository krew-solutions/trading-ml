(** In-process test harness for the Account BC.

    Threads a mutable [ctx] through Given/When/Then steps. Wraps the
    command handler with narrow helpers so scenarios stay declarative.
    No repository, event store or bus is needed — the handler under
    test takes a [Portfolio.t ref] and a [unit -> int] closure
    directly. *)

module H = Account_commands.Reserve_command_handler

type ctx = {
  portfolio : Account.Portfolio.t ref;
  next_reservation_id : unit -> int;
  slippage_buffer : Decimal.t;
  fee_rate : Decimal.t;
  last_event : Account.Portfolio.Events.Amount_reserved.t option;
  last_errors : H.handle_error list option;
}

let make_id_counter () =
  let r = ref 0 in
  fun () ->
    incr r;
    !r

let fresh_ctx () =
  {
    portfolio = ref (Account.Portfolio.empty ~cash:(Decimal.of_int 10_000));
    next_reservation_id = make_id_counter ();
    slippage_buffer = Decimal.of_string "0.01";
    fee_rate = Decimal.of_string "0.001";
    last_event = None;
    last_errors = None;
  }

let with_cash ctx ~cash =
  ctx.portfolio := Account.Portfolio.empty ~cash:(Decimal.of_string cash);
  ctx

let with_slippage ctx ~buffer = { ctx with slippage_buffer = Decimal.of_string buffer }

let with_fee_rate ctx ~rate = { ctx with fee_rate = Decimal.of_string rate }

let reserve ctx ~side ~symbol ~quantity ~price =
  let cmd : Account_commands.Reserve_command.t = { side; symbol; quantity; price } in
  match
    H.handle ~portfolio:ctx.portfolio ~next_reservation_id:ctx.next_reservation_id
      ~slippage_buffer:ctx.slippage_buffer ~fee_rate:ctx.fee_rate cmd
  with
  | Ok ev -> { ctx with last_event = Some ev; last_errors = None }
  | Error es -> { ctx with last_event = None; last_errors = Some es }
