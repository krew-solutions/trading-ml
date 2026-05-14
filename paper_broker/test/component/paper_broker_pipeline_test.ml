(** BDD specification for the paper_broker pipeline: submit → bar →
    fill, with no-lookahead and cancellation flows. *)

module Gherkin = Gherkin_edsl
open Test_harness

let market_buy_fills_on_next_bar_at_open =
  Gherkin.scenario "A market buy submitted before a bar fills on the next bar at its open"
    fresh_ctx
    [
      Gherkin.given "I have submitted a market buy for 10 SBER@MISX with reservation 7"
        (fun ctx ->
          ctx
          |> submit_market_buy ~correlation_id:"saga-A" ~reservation_id:7
               ~symbol:"SBER@MISX" ~quantity:"10" ());
      Gherkin.when_ "the next bar arrives at SBER@MISX with open 100" (fun ctx ->
          ctx |> bar_arrives ~symbol:"SBER@MISX" ~open_:"100" ());
      Gherkin.then_ "the order acceptance is announced" (fun ctx ->
          match !(ctx.order_accepted_pub) with
          | [ ie ] ->
              Alcotest.(check string) "correlation_id" "saga-A" ie.correlation_id;
              Alcotest.(check int) "reservation_id" 7 ie.reservation_id;
              Alcotest.(check string) "quantity" "10" ie.quantity;
              Alcotest.(check string) "side" "BUY" ie.side
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one Order_accepted, got %d" (List.length other)));
      Gherkin.then_ "the fill is observed at the bar's open price" (fun ctx ->
          match !(ctx.order_filled_pub) with
          | [ ie ] ->
              Alcotest.(check string) "correlation_id" "saga-A" ie.correlation_id;
              Alcotest.(check int) "reservation_id" 7 ie.reservation_id;
              Alcotest.(check string) "fill_price = open" "100" ie.fill_price;
              Alcotest.(check string) "fill_quantity = remaining" "10" ie.fill_quantity;
              Alcotest.(check string) "new_total_filled" "10" ie.new_total_filled
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one Order_filled, got %d" (List.length other)));
    ]

let no_lookahead_skips_same_ts_bar_then_fills_on_the_next =
  Gherkin.scenario
    "An order placed at bar T cannot fill at bar T (no-lookahead) but fills at bar T+1"
    fresh_ctx
    [
      Gherkin.given "a bar at 10:00 has already been observed" (fun ctx ->
          ctx |> bar_arrives ~ts:"2024-01-01T10:00:00Z" ~open_:"100" ~close:"101" ());
      Gherkin.and_ "I then submit a market buy" (fun ctx ->
          ctx
          |> submit_market_buy ~correlation_id:"saga-B" ~reservation_id:8 ~quantity:"5" ());
      Gherkin.and_ "a repeat of the same 10:00 bar arrives" (fun ctx ->
          ctx |> bar_arrives ~ts:"2024-01-01T10:00:00Z" ~open_:"100" ~close:"101" ());
      Gherkin.then_ "no fill is observed on the same-ts bar" (fun ctx ->
          Alcotest.(check int)
            "order_filled count" 0
            (List.length !(ctx.order_filled_pub)));
      Gherkin.when_ "the next bar arrives at 10:01" (fun ctx ->
          ctx |> bar_arrives ~ts:"2024-01-01T10:01:00Z" ~open_:"100" ~close:"102" ());
      Gherkin.then_ "the order fills on the later bar" (fun ctx ->
          match !(ctx.order_filled_pub) with
          | [ ie ] ->
              Alcotest.(check int) "reservation_id" 8 ie.reservation_id;
              Alcotest.(check string) "fill_quantity" "5" ie.fill_quantity
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one Order_filled, got %d" (List.length other)));
    ]

let limit_buy_below_market_does_not_fill =
  Gherkin.scenario "A limit buy below the bar's low is not triggered by that bar"
    fresh_ctx
    [
      Gherkin.given "I submitted a limit buy at 90 for 10 SBER@MISX" (fun ctx ->
          ctx
          |> submit_limit_buy ~correlation_id:"saga-C" ~reservation_id:9 ~quantity:"10"
               ~limit:"90" ());
      Gherkin.when_ "a bar arrives that never touches 90" (fun ctx ->
          ctx |> bar_arrives ~open_:"100" ~high:"105" ~low:"95" ~close:"102" ());
      Gherkin.then_ "no fill is observed" (fun ctx ->
          Alcotest.(check int)
            "order_filled count" 0
            (List.length !(ctx.order_filled_pub)));
      Gherkin.then_ "the order is still tracked" (fun ctx ->
          Alcotest.(check int) "store size" 1 (Test_store.length ctx.store));
    ]

let cancellation_announces_release_and_terminalises_the_order =
  Gherkin.scenario "Cancelling a working order announces it and prevents subsequent fills"
    fresh_ctx
    [
      Gherkin.given "a working market buy submitted earlier" (fun ctx ->
          ctx
          |> submit_market_buy ~correlation_id:"saga-D" ~reservation_id:11 ~quantity:"5"
               ());
      Gherkin.when_ "I cancel that order by id" (fun ctx ->
          ctx |> cancel_order ~correlation_id:"cancel-D" ~id:"po-1" ());
      Gherkin.then_ "a cancellation announcement carries the original reservation token"
        (fun ctx ->
          match !(ctx.order_cancelled_pub) with
          | [ ie ] ->
              Alcotest.(check string)
                "correlation_id from cancel" "cancel-D" ie.correlation_id;
              Alcotest.(check int) "reservation_id from pending" 11 ie.reservation_id;
              Alcotest.(check string) "id" "po-1" ie.id
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one Order_cancelled, got %d" (List.length other)));
      Gherkin.when_ "a bar arrives after the cancellation" (fun ctx ->
          ctx |> bar_arrives ~open_:"100" ());
      Gherkin.then_ "no fill is observed because the order is terminal" (fun ctx ->
          Alcotest.(check int)
            "order_filled count" 0
            (List.length !(ctx.order_filled_pub)));
    ]

let invalid_side_is_refused_with_round_trip_reservation_id =
  Gherkin.scenario "A malformed submit is refused, echoing the original reservation token"
    fresh_ctx
    [
      Gherkin.given "a default paper_broker" (fun ctx -> ctx);
      Gherkin.when_ "I submit an order with a malformed side" (fun ctx ->
          let cmd : Paper_broker_commands.Submit_order_command.t =
            {
              correlation_id = "saga-E";
              reservation_id = 42;
              symbol = "SBER@MISX";
              side = "NEITHER";
              quantity = "1";
              kind =
                { type_ = "MARKET"; price = None; stop_price = None; limit_price = None };
              tif = "GTC";
            }
          in
          let publish_accepted e =
            ctx.order_accepted_pub := e :: !(ctx.order_accepted_pub)
          in
          let publish_rejected e =
            ctx.order_rejected_pub := e :: !(ctx.order_rejected_pub)
          in
          let _ =
            Submit_wf.execute ~store:store_module ~store_handle:ctx.store
              ~next_order_id:ctx.next_order_id
              ~now_ts:(fun () -> !(ctx.now_ts_ref))
              ~placed_after_ts:(placed_after_ts_for ctx)
              ~publish_order_accepted:publish_accepted
              ~publish_order_rejected:publish_rejected cmd
          in
          ctx);
      Gherkin.then_ "the refusal carries the original correlation and reservation tokens"
        (fun ctx ->
          match !(ctx.order_rejected_pub) with
          | [ ie ] ->
              Alcotest.(check string) "correlation_id" "saga-E" ie.correlation_id;
              Alcotest.(check int) "reservation_id" 42 ie.reservation_id
          | other ->
              Alcotest.fail
                (Printf.sprintf "expected one Order_rejected, got %d" (List.length other)));
      Gherkin.then_ "the store remains empty" (fun ctx ->
          Alcotest.(check int) "store size" 0 (Test_store.length ctx.store));
    ]

let feature =
  Gherkin.feature "paper_broker pipeline"
    [
      market_buy_fills_on_next_bar_at_open;
      no_lookahead_skips_same_ts_bar_then_fills_on_the_next;
      limit_buy_below_market_does_not_fill;
      cancellation_announces_release_and_terminalises_the_order;
      invalid_side_is_refused_with_round_trip_reservation_id;
    ]
