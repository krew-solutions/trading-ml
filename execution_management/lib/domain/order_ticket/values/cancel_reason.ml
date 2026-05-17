type t = Operator | Kill_switch | Risk_limit_breach

let to_string = function
  | Operator -> "operator"
  | Kill_switch -> "kill_switch"
  | Risk_limit_breach -> "risk_limit_breach"
