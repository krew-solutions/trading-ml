(** Query handler smoke tests against the in-memory ticket store. *)

module Ot = Execution_management.Order_ticket
module Values = Ot.Values
module Store = Execution_management_persistence.In_memory_ticket_store
module Ports = Execution_management_ports
module Q = Execution_management_queries

let qty s = Decimal.of_string s

let intent_buy_100 () =
  let instrument =
    Core.Instrument.make
      ~ticker:(Core.Ticker.of_string "SBER")
      ~venue:(Core.Mic.of_string "MISX") ()
  in
  Values.Trade_intent.make ~book_id:"alpha" ~instrument ~side:Core.Side.Buy
    ~total_quantity:(qty "100")

let store_module = (module Store : Ports.Ticket_store.S with type t = Store.t)

let open_ticket_and_store tid =
  let store = Store.create () in
  let t, _ =
    Ot.open_ticket ~ticket_id:(Values.Ticket_id.of_int tid)
      ~reservation_id:(Values.Reservation_id.of_int tid)
      ~intent:(intent_buy_100 ()) ~directive:Values.Execution_directive.Immediate
      ~now:1_700_000_000L
  in
  Store.put store t;
  store

let test_get_returns_view_model_on_hit () =
  let store = open_ticket_and_store 7 in
  let q : Q.Get_order_ticket_query.t = { ticket_id = 7 } in
  match Q.Get_order_ticket_query_handler.handle store_module ~store_handle:store q with
  | None -> Alcotest.fail "expected Some view model"
  | Some vm -> Alcotest.(check int) "ticket_id" 7 vm.ticket_id

let test_get_returns_none_on_miss () =
  let store = open_ticket_and_store 7 in
  let q : Q.Get_order_ticket_query.t = { ticket_id = 99 } in
  Alcotest.(check bool)
    "miss is None" true
    (Option.is_none
       (Q.Get_order_ticket_query_handler.handle store_module ~store_handle:store q))

let test_get_returns_none_on_malformed_id () =
  let store = open_ticket_and_store 7 in
  let q : Q.Get_order_ticket_query.t = { ticket_id = 0 } in
  Alcotest.(check bool)
    "non-positive id rejected to None" true
    (Option.is_none
       (Q.Get_order_ticket_query_handler.handle store_module ~store_handle:store q))

let test_list_open_returns_all_non_terminal () =
  let store = Store.create () in
  List.iter
    (fun tid ->
      let t, _ =
        Ot.open_ticket ~ticket_id:(Values.Ticket_id.of_int tid)
          ~reservation_id:(Values.Reservation_id.of_int tid)
          ~intent:(intent_buy_100 ()) ~directive:Values.Execution_directive.Immediate
          ~now:1_700_000_000L
      in
      Store.put store t)
    [ 1; 2; 3 ];
  let q : Q.List_open_order_tickets_query.t = { book_id = None } in
  let result =
    Q.List_open_order_tickets_query_handler.handle store_module ~store_handle:store q
  in
  Alcotest.(check int) "three open tickets surfaced" 3 (List.length result)

let tests =
  [
    Alcotest.test_case "Get hit → Some view model" `Quick
      test_get_returns_view_model_on_hit;
    Alcotest.test_case "Get miss → None" `Quick test_get_returns_none_on_miss;
    Alcotest.test_case "Get malformed id → None" `Quick
      test_get_returns_none_on_malformed_id;
    Alcotest.test_case "List open returns every non-terminal ticket" `Quick
      test_list_open_returns_all_non_terminal;
  ]
