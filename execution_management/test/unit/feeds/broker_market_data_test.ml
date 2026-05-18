(** Unit tests for {!Execution_management_feeds.Broker_market_data}.

    Per-instrument callback registry; mirrors the volume-feed
    adapter but with no timeframe filter and a [Market_data_quote.t]
    payload. *)

module Feed = Execution_management_feeds.Broker_market_data
module Mq = Execution_management.Order_ticket.Values.Market_data_quote

let instrument_sber = Core.Instrument.of_qualified "SBER@MISX"
let instrument_gazp = Core.Instrument.of_qualified "GAZP@MISX"

let quote ~price =
  let p = Decimal.of_string price in
  Mq.make ~ts:0L ~bid:p ~ask:p ~realised_volatility:0.0

let delivers_to_matching_subscriber () =
  let t = Feed.create () in
  let received = ref 0 in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber
      ~on_quote:(fun _ -> incr received)
  in
  Feed.deliver t ~instrument:instrument_sber ~quote:(quote ~price:"100");
  Alcotest.(check int) "one delivery" 1 !received

let does_not_deliver_to_other_instrument () =
  let t = Feed.create () in
  let received = ref 0 in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber
      ~on_quote:(fun _ -> incr received)
  in
  Feed.deliver t ~instrument:instrument_gazp ~quote:(quote ~price:"100");
  Alcotest.(check int) "no delivery" 0 !received

let unsubscribe_stops_deliveries () =
  let t = Feed.create () in
  let received = ref 0 in
  let sub =
    Feed.subscribe t ~instrument:instrument_sber
      ~on_quote:(fun _ -> incr received)
  in
  Feed.deliver t ~instrument:instrument_sber ~quote:(quote ~price:"100");
  Feed.unsubscribe t sub;
  Feed.deliver t ~instrument:instrument_sber ~quote:(quote ~price:"105");
  Alcotest.(check int) "only one delivery counted" 1 !received

let tests =
  [
    Alcotest.test_case "delivers to matching subscriber" `Quick
      delivers_to_matching_subscriber;
    Alcotest.test_case "no delivery to other instrument" `Quick
      does_not_deliver_to_other_instrument;
    Alcotest.test_case "unsubscribe stops deliveries" `Quick
      unsubscribe_stops_deliveries;
  ]
