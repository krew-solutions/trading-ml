open Core

let candle_equal (a : Candle.t) (b : Candle.t) =
  Int64.equal a.ts b.ts && Decimal.equal a.open_ b.open_ && Decimal.equal a.high b.high
  && Decimal.equal a.low b.low && Decimal.equal a.close b.close
  && Decimal.equal a.volume b.volume

let make ~bus =
  let state : (Instrument.t * Timeframe.t, int64 option ref * Candle.t list ref) Hashtbl.t
      =
    Hashtbl.create 16
  in
  let bus_publish =
    Bus.publish
      (Bus.producer bus ~uri:"in-memory://broker.bar-updated" ~serialize:(fun v ->
           Yojson.Safe.to_string
             (Broker_integration_events.Bar_updated_integration_event.yojson_of_t v)))
  in
  fun ~(instrument : Instrument.t) ~(timeframe : Timeframe.t) ~(candle : Candle.t) ->
    let key = (instrument, timeframe) in
    let tail_ts, sent_at_tail =
      match Hashtbl.find_opt state key with
      | Some pair -> pair
      | None ->
          let pair = (ref None, ref []) in
          Hashtbl.add state key pair;
          pair
    in
    let should_publish =
      match !tail_ts with
      | None ->
          tail_ts := Some candle.ts;
          sent_at_tail := [ candle ];
          true
      | Some t when Int64.compare candle.ts t < 0 -> false
      | Some t when Int64.compare candle.ts t > 0 ->
          tail_ts := Some candle.ts;
          sent_at_tail := [ candle ];
          true
      | Some _ ->
          if List.exists (candle_equal candle) !sent_at_tail then false
          else begin
            sent_at_tail := candle :: !sent_at_tail;
            true
          end
    in
    if should_publish then
      bus_publish
        (Broker_integration_events.Bar_updated_integration_event.of_domain ~instrument
           ~timeframe ~candle)
