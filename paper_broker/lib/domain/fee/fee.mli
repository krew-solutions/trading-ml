module Values : module type of Values

(** Pure fee calculation: [fee = quantity * price * rate].

    Always non-negative because [Fee_rate.t] is bounded to
    [\[0, 1)] and [quantity], [price] are required positive. *)

val compute : rate:Values.Fee_rate.t -> quantity:Decimal.t -> price:Decimal.t -> Decimal.t
(*@ f = compute ~rate ~quantity ~price
    ensures rate = Values.Fee_rate.zero -> f = Decimal.zero *)
