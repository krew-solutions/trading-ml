(** Unit tests for {!Paper_broker.Fee}. *)

module Fee_rate = Paper_broker.Fee.Values.Fee_rate
module Fee = Paper_broker.Fee

let dec = Decimal.of_string

let test_negative_rate_rejected () =
  match Fee_rate.of_decimal (dec "-0.001") with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail "expected Invalid_argument for negative rate"

let test_rate_one_rejected () =
  match Fee_rate.of_decimal (dec "1") with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail "expected Invalid_argument for rate = 1"

let test_zero_rate_compute_is_zero () =
  let rate = Fee_rate.zero in
  let f = Fee.compute ~rate ~quantity:(dec "10") ~price:(dec "100") in
  Alcotest.(check bool) "fee = 0 when rate = 0" true (Decimal.is_zero f)

let test_compute_qty_price_rate () =
  let rate = Fee_rate.of_decimal (dec "0.001") in
  let f = Fee.compute ~rate ~quantity:(dec "10") ~price:(dec "100") in
  Alcotest.(check string) "10 * 100 * 0.001 = 1" "1" (Decimal.to_string f)

let tests =
  [
    ("negative rate rejected", `Quick, test_negative_rate_rejected);
    ("rate = 1 rejected", `Quick, test_rate_one_rejected);
    ("zero rate => zero fee", `Quick, test_zero_rate_compute_is_zero);
    ("compute = qty * price * rate", `Quick, test_compute_qty_price_rate);
  ]
