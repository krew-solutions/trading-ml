(** Integration event: Account reserved cash / quantity for a
    pending order.

    Published by {!Reserve_command_workflow} after
    {!Account.Portfolio.try_reserve} succeeds. [reservation_id]
    is the cross-BC saga key — the
    inbound HTTP adapter propagates it into {!Submit_order_command.t}
    so Broker echoes it back, and the Account compensation
    subscriber matches by it on rejection.

    DTO-shaped: primitives + nested view model, no domain values.
    [@@deriving yojson] auto-generates the on-wire format. *)

type t = {
  reservation_id : int;
  side : string;
  instrument : Queries.Instrument_view_model.t;
  quantity : float;
  price : float;
  reserved_cash : float;
}
[@@deriving yojson]

type domain = Account.Portfolio.Events.Amount_reserved.t

val of_domain : domain -> t
