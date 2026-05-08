type t = { instrument : Core.Instrument.t; quantity : Decimal.t; avg_price : Decimal.t }

let make ~instrument ~quantity ~avg_price = { instrument; quantity; avg_price }

let instrument t = t.instrument
let quantity t = t.quantity
let avg_price t = t.avg_price
