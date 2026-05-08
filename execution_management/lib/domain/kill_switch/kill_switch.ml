module Values = Values
module Events = Events

type t = {
  peak_equity : Decimal.t;
  max_drawdown_pct : Values.Max_drawdown_pct.t;
  halted : bool;
}

let make ~initial_equity ~max_drawdown_pct =
  { peak_equity = initial_equity; max_drawdown_pct; halted = false }

let peak_equity t = t.peak_equity
let is_halted t = t.halted
let max_drawdown_pct t = t.max_drawdown_pct

let update_equity t ~equity ~occurred_at =
  let pct = Values.Max_drawdown_pct.to_float t.max_drawdown_pct in
  if pct <= 0.0 then (t, None)
  else
    let peak =
      if Decimal.compare equity t.peak_equity > 0 then equity else t.peak_equity
    in
    let peak_f = Decimal.to_float peak in
    let curr_f = Decimal.to_float equity in
    if peak_f <= 0.0 then ({ t with peak_equity = peak }, None)
    else
      let drawdown = (peak_f -. curr_f) /. peak_f in
      if (not t.halted) && drawdown > pct then
        let event =
          Events.Tripped.make ~peak_equity:peak ~current_equity:equity ~drawdown
            ~occurred_at
        in
        ({ t with peak_equity = peak; halted = true }, Some event)
      else ({ t with peak_equity = peak }, None)

let reset t ~new_peak_equity ~occurred_at =
  let event = Events.Reset.make ~new_peak_equity ~occurred_at in
  ({ t with peak_equity = new_peak_equity; halted = false }, event)
