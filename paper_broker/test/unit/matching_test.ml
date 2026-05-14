(** Unit tests for {!Paper_broker.Matching.price_if_filled}. *)

module Order_kind = Paper_broker.Order.Values.Order_kind
module Matching = Paper_broker.Matching

let dec = Decimal.of_string

let make_candle ~open_ ~high ~low ~close =
  Core.Candle.make ~ts:1_700_000_000L ~open_:(dec open_) ~high:(dec high) ~low:(dec low)
    ~close:(dec close) ~volume:(dec "1000")

let check_some msg ~expected got =
  match got with
  | Some d -> Alcotest.(check string) msg expected (Decimal.to_string d)
  | None -> Alcotest.fail (msg ^ ": expected Some, got None")

let check_none msg got =
  match got with
  | None -> ()
  | Some d ->
      Alcotest.fail
        (msg ^ Printf.sprintf ": expected None, got Some %s" (Decimal.to_string d))

(* Market always fills at open *)
let test_market_buy_fills_at_open () =
  let candle = make_candle ~open_:"100" ~high:"105" ~low:"95" ~close:"102" in
  let r = Matching.price_if_filled ~kind:Order_kind.market ~side:Core.Side.Buy ~candle in
  check_some "market buy" ~expected:"100" r

let test_market_sell_fills_at_open () =
  let candle = make_candle ~open_:"100" ~high:"105" ~low:"95" ~close:"102" in
  let r = Matching.price_if_filled ~kind:Order_kind.market ~side:Core.Side.Sell ~candle in
  check_some "market sell" ~expected:"100" r

(* Buy limit: fills when bar is at-or-below the limit *)
let test_limit_buy_fills_at_open_when_gapped () =
  let candle = make_candle ~open_:"99" ~high:"100" ~low:"98" ~close:"99" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.limit (dec "100"))
      ~side:Core.Side.Buy ~candle
  in
  check_some "limit buy gapped past" ~expected:"99" r

let test_limit_buy_fills_at_limit_when_touched () =
  let candle = make_candle ~open_:"105" ~high:"107" ~low:"99" ~close:"106" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.limit (dec "100"))
      ~side:Core.Side.Buy ~candle
  in
  check_some "limit buy intra-bar touch" ~expected:"100" r

let test_limit_buy_no_fill_when_above () =
  let candle = make_candle ~open_:"105" ~high:"107" ~low:"103" ~close:"106" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.limit (dec "100"))
      ~side:Core.Side.Buy ~candle
  in
  check_none "limit buy above range" r

(* Sell limit: mirror — fills when bar is at-or-above the limit *)
let test_limit_sell_fills_at_open_when_gapped () =
  let candle = make_candle ~open_:"101" ~high:"102" ~low:"100" ~close:"101" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.limit (dec "100"))
      ~side:Core.Side.Sell ~candle
  in
  check_some "limit sell gapped past" ~expected:"101" r

let test_limit_sell_no_fill_when_below () =
  let candle = make_candle ~open_:"95" ~high:"99" ~low:"93" ~close:"97" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.limit (dec "100"))
      ~side:Core.Side.Sell ~candle
  in
  check_none "limit sell below range" r

(* Stop Buy: trigger when bar prints at-or-above stop *)
let test_stop_buy_fills_at_open_when_gapped () =
  let candle = make_candle ~open_:"105" ~high:"107" ~low:"104" ~close:"106" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.stop (dec "100"))
      ~side:Core.Side.Buy ~candle
  in
  check_some "stop buy gapped past" ~expected:"105" r

let test_stop_buy_fills_at_stop_when_touched () =
  let candle = make_candle ~open_:"99" ~high:"101" ~low:"98" ~close:"100" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.stop (dec "100"))
      ~side:Core.Side.Buy ~candle
  in
  check_some "stop buy intra-bar touch" ~expected:"100" r

let test_stop_buy_no_fill_when_below () =
  let candle = make_candle ~open_:"95" ~high:"99" ~low:"93" ~close:"97" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.stop (dec "100"))
      ~side:Core.Side.Buy ~candle
  in
  check_none "stop buy below range" r

(* Stop Sell: mirror — trigger when bar prints at-or-below stop *)
let test_stop_sell_fills_at_open_when_gapped () =
  let candle = make_candle ~open_:"95" ~high:"99" ~low:"93" ~close:"94" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.stop (dec "100"))
      ~side:Core.Side.Sell ~candle
  in
  check_some "stop sell gapped past" ~expected:"95" r

(* Stop_limit: not simulated yet *)
let test_stop_limit_returns_none () =
  let candle = make_candle ~open_:"100" ~high:"105" ~low:"95" ~close:"102" in
  let r =
    Matching.price_if_filled
      ~kind:(Order_kind.stop_limit ~stop:(dec "100") ~limit:(dec "101"))
      ~side:Core.Side.Buy ~candle
  in
  check_none "stop_limit always none" r

let tests =
  [
    ("market buy fills at open", `Quick, test_market_buy_fills_at_open);
    ("market sell fills at open", `Quick, test_market_sell_fills_at_open);
    ("limit buy: gap past fills at open", `Quick, test_limit_buy_fills_at_open_when_gapped);
    ("limit buy: touch fills at limit", `Quick, test_limit_buy_fills_at_limit_when_touched);
    ("limit buy: no fill above range", `Quick, test_limit_buy_no_fill_when_above);
    ( "limit sell: gap past fills at open",
      `Quick,
      test_limit_sell_fills_at_open_when_gapped );
    ("limit sell: no fill below range", `Quick, test_limit_sell_no_fill_when_below);
    ("stop buy: gap past fills at open", `Quick, test_stop_buy_fills_at_open_when_gapped);
    ("stop buy: touch fills at stop", `Quick, test_stop_buy_fills_at_stop_when_touched);
    ("stop buy: no fill below range", `Quick, test_stop_buy_no_fill_when_below);
    ("stop sell: gap past fills at open", `Quick, test_stop_sell_fills_at_open_when_gapped);
    ("stop_limit always returns none", `Quick, test_stop_limit_returns_none);
  ]
