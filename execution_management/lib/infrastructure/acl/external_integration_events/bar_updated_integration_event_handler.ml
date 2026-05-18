module Vb = Execution_management.Order_ticket.Values.Volume_bar
module Mq = Execution_management.Order_ticket.Values.Market_data_quote

let parse_instrument
    (vm : Instrument_view_model.t) : Core.Instrument.t option =
  let qualified =
    match vm.board with
    | Some b -> Printf.sprintf "%s@%s/%s" vm.ticker vm.venue b
    | None -> Printf.sprintf "%s@%s" vm.ticker vm.venue
  in
  try Some (Core.Instrument.of_qualified qualified)
  with Invalid_argument _ -> None

let parse_volume_bar ~ts (c : Candle_view_model.t) : Vb.t option =
  try
    let volume = Decimal.of_string c.volume in
    if Decimal.compare volume Decimal.zero < 0 then None
    else Some (Vb.make ~ts ~volume)
  with Invalid_argument _ -> None

let parse_market_data_quote ~ts (c : Candle_view_model.t) : Mq.t option =
  try
    let close = Decimal.of_string c.close in
    if Decimal.compare close Decimal.zero <= 0 then None
    else
      Some
        (Mq.make ~ts ~bid:close ~ask:close ~realised_volatility:0.0)
  with Invalid_argument _ -> None

(** Single-bar fan-out: parses the wire bar, then delivers
    [Volume_bar] to the volume-feed adapter and a synthesised
    [Market_data_quote] (bid = ask = close, realised_volatility = 0)
    to the market-data adapter. Malformed instruments / candles
    are silently dropped — the broker side is the source of truth
    for valid bars, and a single bad bar should not propagate
    into a domain invariant violation. *)
let handle
    ~(deliver_volume_bar :
       instrument:Core.Instrument.t -> timeframe:string -> bar:Vb.t -> unit)
    ~(deliver_market_data :
       instrument:Core.Instrument.t -> quote:Mq.t -> unit)
    (ev : Bar_updated_integration_event.t) : unit =
  match parse_instrument ev.instrument with
  | None -> ()
  | Some instrument ->
      let ts = Datetime.Iso8601.parse ev.candle.ts in
      (match parse_volume_bar ~ts ev.candle with
      | None -> ()
      | Some bar ->
          deliver_volume_bar ~instrument ~timeframe:ev.timeframe ~bar);
      match parse_market_data_quote ~ts ev.candle with
      | None -> ()
      | Some quote -> deliver_market_data ~instrument ~quote
