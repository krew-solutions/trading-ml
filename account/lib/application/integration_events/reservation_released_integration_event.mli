(** Integration event: Account released a previously-reserved
    earmark. Published by {!Release_command_workflow} when
    {!Account.Portfolio.release} returns [Some _] — compensation
    completion. The released cash / quantity is again available
    to subsequent commands. *)

type t = {
  reservation_id : int;
  side : string;
  instrument : Account_queries.Instrument_view_model.t;
}
[@@deriving yojson]

type domain = Account.Portfolio.Events.Reservation_released.t

val of_domain : domain -> t
