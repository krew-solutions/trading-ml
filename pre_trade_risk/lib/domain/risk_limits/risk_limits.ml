type t = {
  min_cash_buffer : Decimal.t;
  max_gross_exposure : Decimal.t;
  max_leverage : float;
}

let make ~min_cash_buffer ~max_gross_exposure ~max_leverage =
  if Decimal.is_negative min_cash_buffer then
    invalid_arg "Risk_limits.make: min_cash_buffer must be >= 0";
  if Decimal.is_negative max_gross_exposure then
    invalid_arg "Risk_limits.make: max_gross_exposure must be >= 0";
  if max_leverage <= 0.0 then invalid_arg "Risk_limits.make: max_leverage must be > 0";
  { min_cash_buffer; max_gross_exposure; max_leverage }

let default ~equity =
  make
    ~min_cash_buffer:(Decimal.div equity (Decimal.of_int 20))
    ~max_gross_exposure:(Decimal.mul equity (Decimal.of_int 2))
    ~max_leverage:2.0

let min_cash_buffer t = t.min_cash_buffer
let max_gross_exposure t = t.max_gross_exposure
let max_leverage t = t.max_leverage
