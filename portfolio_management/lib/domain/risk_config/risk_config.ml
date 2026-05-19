type t = {
  book_id : Common.Book_id.t;
  risk_budget_fraction : Decimal.t;
  limits : Risk.Values.Risk_limits.t;
  construction_source : Common.Source.t;
  sizing_policy : Common.Sizing_policy_choice.t;
}

let validate_sizing_policy = function
  | Common.Sizing_policy_choice.Equity_proportional -> ()
  | Common.Sizing_policy_choice.Volatility_target { target_annual_vol } ->
      if Decimal.is_negative target_annual_vol then
        invalid_arg
          (Printf.sprintf
             "Risk_config.make: Volatility_target.target_annual_vol must be \
              >= 0 (got %s)"
             (Decimal.to_string target_annual_vol))

let make ~book_id ~risk_budget_fraction ~limits ~construction_source
    ~sizing_policy =
  if Decimal.is_negative risk_budget_fraction
     || Decimal.compare risk_budget_fraction Decimal.one > 0
  then
    invalid_arg
      (Printf.sprintf
         "Risk_config.make: risk_budget_fraction must be in [0, 1] (got %s)"
         (Decimal.to_string risk_budget_fraction));
  validate_sizing_policy sizing_policy;
  {
    book_id;
    risk_budget_fraction;
    limits;
    construction_source;
    sizing_policy;
  }

let book_id t = t.book_id
let risk_budget_fraction t = t.risk_budget_fraction
let limits t = t.limits
let construction_source t = t.construction_source
let sizing_policy t = t.sizing_policy

let book_equity t ~total_equity =
  Decimal.mul total_equity t.risk_budget_fraction

let authorises t s = Common.Source.equal t.construction_source s
