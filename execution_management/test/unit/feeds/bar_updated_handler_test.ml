(** Unit tests for the [Bar_updated_integration_event_handler]
    fan-out: one wire bar lands in two ports (volume + market
    data) with the right typed shapes. *)

module Handler = Execution_management_external_integration_events.Bar_updated_integration_event_handler
module Ie = Execution_management_external_integration_events.Bar_updated_integration_event
module Iqr = Execution_management_external_view_models
module Vb = Execution_management.Order_ticket.Values.Volume_bar
module Mq = Execution_management.Order_ticket.Values.Market_data_quote

let sber_vm : Iqr.Instrument_view_model.t =
  { ticker = "SBER"; venue = "MISX"; isin = None; board = None }

let make_ev ?(open_ = "100") ?(high = "101") ?(low = "99") ?(close = "100.5")
    ?(volume = "1000") ?(timeframe = "1m")
    ?(ts = "2024-01-15T13:45:00Z") () : Ie.t =
  {
    instrument = sber_vm;
    timeframe;
    candle = { ts; open_; high; low; close; volume };
  }

let fans_out_volume_and_market_data () =
  let vol_calls = ref [] in
  let md_calls = ref [] in
  Handler.handle
    ~deliver_volume_bar:(fun ~instrument ~timeframe ~bar ->
      vol_calls := (instrument, timeframe, bar) :: !vol_calls)
    ~deliver_market_data:(fun ~instrument ~quote ->
      md_calls := (instrument, quote) :: !md_calls)
    (make_ev ());
  Alcotest.(check int) "one volume delivery" 1 (List.length !vol_calls);
  Alcotest.(check int) "one market_data delivery" 1 (List.length !md_calls);
  let _, tf, bar = List.hd !vol_calls in
  Alcotest.(check string) "timeframe forwarded" "1m" tf;
  Alcotest.(check string) "volume forwarded" "1000"
    (Decimal.to_string bar.volume);
  let _, q = List.hd !md_calls in
  Alcotest.(check string) "bid = close" "100.5" (Decimal.to_string q.bid);
  Alcotest.(check string) "ask = close" "100.5" (Decimal.to_string q.ask);
  Alcotest.(check (float 0.0001)) "vol = 0" 0.0 q.realised_volatility

let drops_when_close_is_zero () =
  let vol_calls = ref 0 in
  let md_calls = ref 0 in
  Handler.handle
    ~deliver_volume_bar:(fun ~instrument:_ ~timeframe:_ ~bar:_ ->
      incr vol_calls)
    ~deliver_market_data:(fun ~instrument:_ ~quote:_ -> incr md_calls)
    (make_ev ~close:"0" ());
  Alcotest.(check int) "volume still delivered" 1 !vol_calls;
  Alcotest.(check int) "market_data dropped (invariant guard)" 0 !md_calls

let drops_when_volume_is_negative () =
  let vol_calls = ref 0 in
  let md_calls = ref 0 in
  Handler.handle
    ~deliver_volume_bar:(fun ~instrument:_ ~timeframe:_ ~bar:_ ->
      incr vol_calls)
    ~deliver_market_data:(fun ~instrument:_ ~quote:_ -> incr md_calls)
    (make_ev ~volume:"-10" ());
  Alcotest.(check int) "volume dropped (invariant guard)" 0 !vol_calls;
  Alcotest.(check int) "market_data still delivered" 1 !md_calls

let tests =
  [
    Alcotest.test_case "one bar fans out to volume and market_data" `Quick
      fans_out_volume_and_market_data;
    Alcotest.test_case "close ≤ 0 drops market_data only" `Quick
      drops_when_close_is_zero;
    Alcotest.test_case "negative volume drops volume only" `Quick
      drops_when_volume_is_negative;
  ]
