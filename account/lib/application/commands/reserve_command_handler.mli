(** Command handler for {!Reserve_command.t}.

    Single responsibility: invoke {!Account.Portfolio.try_reserve}
    on the shared portfolio ref, mutate it on success, and return
    the resulting domain event. Does not publish, does not touch
    integration events — that is the workflow's job composed by
    {!Reserve_command_workflow.execute}.

    Inputs are already-parsed domain values; raw {!Reserve_command.t}
    parsing happens upstream in the workflow so this handler stays
    a pure transition over [Account.Portfolio.t]. *)

val handle :
  portfolio:Account.Portfolio.t ref ->
  id:int ->
  side:Core.Side.t ->
  instrument:Core.Instrument.t ->
  quantity:Core.Decimal.t ->
  price:Core.Decimal.t ->
  slippage_buffer:float ->
  fee_rate:float ->
  (Account.Portfolio.Events.Amount_reserved.t, Account.Portfolio.reservation_error) Rop.t
