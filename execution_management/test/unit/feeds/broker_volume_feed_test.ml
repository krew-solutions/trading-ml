(** Unit tests for {!Execution_management_feeds.Broker_volume_feed}.

    The adapter is a passive callback registry: subscriber gets
    called only on bars whose [instrument] and [timeframe] match
    the subscription parameters. *)

module Feed = Execution_management_feeds.Broker_volume_feed
module Vb = Execution_management.Order_ticket.Values.Volume_bar

let instrument_sber =
  Core.Instrument.of_qualified "SBER@MISX"

let instrument_gazp =
  Core.Instrument.of_qualified "GAZP@MISX"

let bar ~vol =
  Vb.make ~ts:0L ~volume:(Decimal.of_string vol)

let delivers_to_matching_subscriber () =
  let t = Feed.create () in
  let received = ref [] in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber ~timeframe:"1m"
      ~on_bar:(fun b -> received := b :: !received)
  in
  Feed.deliver t ~instrument:instrument_sber ~timeframe:"1m" ~bar:(bar ~vol:"100");
  Alcotest.(check int) "one delivery" 1 (List.length !received)

let does_not_deliver_to_other_instrument () =
  let t = Feed.create () in
  let received = ref 0 in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber ~timeframe:"1m"
      ~on_bar:(fun _ -> incr received)
  in
  Feed.deliver t ~instrument:instrument_gazp ~timeframe:"1m"
    ~bar:(bar ~vol:"100");
  Alcotest.(check int) "no delivery" 0 !received

let does_not_deliver_to_other_timeframe () =
  let t = Feed.create () in
  let received = ref 0 in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber ~timeframe:"1m"
      ~on_bar:(fun _ -> incr received)
  in
  Feed.deliver t ~instrument:instrument_sber ~timeframe:"5m"
    ~bar:(bar ~vol:"100");
  Alcotest.(check int) "no delivery" 0 !received

let two_subscribers_same_key_both_fire () =
  let t = Feed.create () in
  let a = ref 0 in
  let b = ref 0 in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber ~timeframe:"1m"
      ~on_bar:(fun _ -> incr a)
  in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber ~timeframe:"1m"
      ~on_bar:(fun _ -> incr b)
  in
  Feed.deliver t ~instrument:instrument_sber ~timeframe:"1m"
    ~bar:(bar ~vol:"100");
  Alcotest.(check int) "a got it" 1 !a;
  Alcotest.(check int) "b got it" 1 !b

let unsubscribe_stops_deliveries () =
  let t = Feed.create () in
  let received = ref 0 in
  let sub =
    Feed.subscribe t ~instrument:instrument_sber ~timeframe:"1m"
      ~on_bar:(fun _ -> incr received)
  in
  Feed.deliver t ~instrument:instrument_sber ~timeframe:"1m"
    ~bar:(bar ~vol:"100");
  Feed.unsubscribe t sub;
  Feed.deliver t ~instrument:instrument_sber ~timeframe:"1m"
    ~bar:(bar ~vol:"200");
  Alcotest.(check int) "only one delivery counted" 1 !received

let raising_subscriber_does_not_block_others () =
  let t = Feed.create () in
  let other = ref 0 in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber ~timeframe:"1m"
      ~on_bar:(fun _ -> raise (Failure "boom"))
  in
  let _ : Feed.subscription =
    Feed.subscribe t ~instrument:instrument_sber ~timeframe:"1m"
      ~on_bar:(fun _ -> incr other)
  in
  Feed.deliver t ~instrument:instrument_sber ~timeframe:"1m"
    ~bar:(bar ~vol:"100");
  Alcotest.(check int) "second subscriber still got the bar" 1 !other

let tests =
  [
    Alcotest.test_case "delivers to matching subscriber" `Quick
      delivers_to_matching_subscriber;
    Alcotest.test_case "no delivery to other instrument" `Quick
      does_not_deliver_to_other_instrument;
    Alcotest.test_case "no delivery to other timeframe" `Quick
      does_not_deliver_to_other_timeframe;
    Alcotest.test_case "two subscribers same key both fire" `Quick
      two_subscribers_same_key_both_fire;
    Alcotest.test_case "unsubscribe stops deliveries" `Quick
      unsubscribe_stops_deliveries;
    Alcotest.test_case "raising subscriber does not block others" `Quick
      raising_subscriber_does_not_block_others;
  ]
