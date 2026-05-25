(** Client-supplied identifier of an order, in the brokerage Domain.

    Plays the role that FIX [clOrdID] plays in a real brokerage:
    the brokerage receives this identifier alongside the new-order
    intent, stores it as part of the order's identity, and echoes
    it on every lifecycle event the brokerage emits to the client
    (Order_accepted, Trade_executed, Order_cancelled, Order_rejected).

    In our system the only client of paper_broker is the
    execution_management saga, which threads the Account-side
    [placement_id] (a monotonic positive integer) through every
    [Submit_order_command]. paper_broker treats the value as
    opaque — it does not interpret it as a "reservation" in the
    Account sense; for paper_broker's Domain it is simply "the
    client's identifier of this order".

    Invariant: [placement_id > 0]. Catches malformed wire
    payloads at the validation boundary; pins a Domain assumption
    Why3 can use. *)

type t = private int

val of_int : int -> t
(** Raises [Invalid_argument] when [n <= 0]. *)

val to_int : t -> int

val equal : t -> t -> bool
val compare : t -> t -> int
