(** Pre-trade risk gate. Pure function over proposed order + current
    portfolio + limits → accepted order quantity (possibly reduced) or
    rejection reason. *)

open Core

type limits = {
  max_position_notional : Decimal.t;   (** per-symbol cap *)
  max_gross_exposure : Decimal.t;      (** sum of |pos|·price *)
  max_leverage : float;                (** gross / equity *)
  min_cash_buffer : Decimal.t;         (** never spend below this *)
}

let default_limits ~equity = {
  max_position_notional = Decimal.div equity (Decimal.of_int 5);
  max_gross_exposure = Decimal.mul equity (Decimal.of_int 2);
  max_leverage = 2.0;
  min_cash_buffer = Decimal.div equity (Decimal.of_int 20);
}

type decision =
  | Accept of Decimal.t           (** possibly-reduced quantity *)
  | Reject of string

(** Size a position from a fraction of equity, clamped by the per-symbol
    notional cap. Returns a positive quantity in lots (decimal units). *)
let size_from_strength
    ~(equity : Decimal.t)
    ~(price : Decimal.t)
    ~(limits : limits)
    ~(strength : float) : Decimal.t =
  let f = Float.max 0.0 (Float.min 1.0 strength) in
  let budget = Decimal.mul equity (Decimal.of_float f) in
  let budget = Decimal.min budget limits.max_position_notional in
  if Decimal.is_zero price then Decimal.zero
  else Decimal.div budget price

let check
    ~(portfolio : Portfolio.t)
    ~(limits : limits)
    ~symbol:(_symbol : Symbol.t)
    ~(side : Side.t)
    ~(quantity : Decimal.t)
    ~(price : Decimal.t)
    ~(mark : Symbol.t -> Decimal.t option)
  : decision =
  if Decimal.is_zero quantity then Reject "zero quantity"
  else if Decimal.is_zero price then Reject "zero price"
  else
    let notional = Decimal.mul quantity price in
    let new_cash = match side with
      | Side.Buy -> Decimal.sub portfolio.cash notional
      | Sell -> Decimal.add portfolio.cash notional
    in
    if Decimal.compare new_cash limits.min_cash_buffer < 0 then
      Reject "would breach min_cash_buffer"
    else
      let gross =
        List.fold_left (fun acc (_, (pos : Portfolio.position)) ->
          let p = match mark pos.symbol with
            | Some m -> m | None -> pos.avg_price
          in
          Decimal.add acc (Decimal.abs (Decimal.mul pos.quantity p)))
          Decimal.zero portfolio.positions
      in
      let gross' = Decimal.add gross notional in
      if Decimal.compare gross' limits.max_gross_exposure > 0 then
        Reject "max_gross_exposure"
      else
        let equity = Portfolio.equity portfolio mark in
        if Decimal.is_positive equity then
          let lev =
            Decimal.to_float gross' /. Decimal.to_float equity
          in
          if lev > limits.max_leverage then Reject "max_leverage"
          else Accept quantity
        else Reject "non-positive equity"
