(** Unit tests for [Bcs.Rest]: URL construction, query params,
    response decoding including BCS-specific quirks (newest-first
    ordering, plain-float decimals). *)

open Core
open Bcs

let make_cfg () =
  Config.make
    ~refresh_token:"R"
    ~rest_base:(Uri.of_string "https://api.test")
    ~token_endpoint:(Uri.of_string "https://api.test/token")
    ()

(** Fake transport that answers token exchange first, then the caller's
    actual request, capturing the second one for assertions. *)
let scripted_transport ~bars_response : Http_transport.t * Http_transport.request ref =
  let captured = ref None in
  let count = ref 0 in
  let t : Http_transport.t = fun req ->
    incr count;
    if !count = 1 then
      (* Auth: token exchange *)
      { status = 200;
        body = Yojson.Safe.to_string (`Assoc [
          "access_token", `String "ACCESS";
          "expires_in",   `Int 600;
        ]) }
    else begin
      captured := Some req;
      { status = 200; body = bars_response }
    end
  in
  let out = ref {
    Http_transport.meth = `GET;
    url = Uri.empty;
    headers = [];
    body = None;
  } in
  let t' = fun req ->
    let resp = t req in
    (match !captured with
     | Some r -> out := r
     | None -> ());
    resp
  in
  t', out

let sample_bars_newest_first = {|
  {
    "ticker": "SBER",
    "classCode": "TQBR",
    "timeFrame": "H1",
    "bars": [
      { "time": "2026-04-15T10:00:00.000Z", "open": 320.0, "high": 321.0,
        "low": 319.5, "close": 320.5, "volume": 1500.0 },
      { "time": "2026-04-15T09:00:00.000Z", "open": 319.5, "high": 320.2,
        "low": 319.0, "close": 320.0, "volume": 2000.0 },
      { "time": "2026-04-15T08:00:00.000Z", "open": 319.0, "high": 320.0,
        "low": 318.8, "close": 319.5, "volume": 1800.0 }
    ]
  }|}

let test_bars_request_url_and_params () =
  let t, captured = scripted_transport ~bars_response:sample_bars_newest_first in
  let cfg = make_cfg () in
  let rest = Rest.make ~transport:t ~cfg in
  let _ = Rest.bars rest ~n:100
    ~symbol:(Symbol.of_string "SBER@TQBR") ~timeframe:H1 in
  let req = !captured in
  Alcotest.(check bool) "GET" true (req.meth = `GET);
  let path = Uri.path req.url in
  Alcotest.(check string) "path"
    "/trade-api-market-data-connector/api/v1/candles-chart" path;
  let qp name =
    match Uri.get_query_param req.url name with
    | Some v -> v | None -> "<missing>"
  in
  Alcotest.(check string) "ticker"    "SBER" (qp "ticker");
  Alcotest.(check string) "classCode" "TQBR" (qp "classCode");
  Alcotest.(check string) "timeFrame" "H1"   (qp "timeFrame");
  Alcotest.(check bool) "startDate present" true
    (Option.is_some (Uri.get_query_param req.url "startDate"));
  Alcotest.(check bool) "endDate present" true
    (Option.is_some (Uri.get_query_param req.url "endDate"))

let test_bars_sorted_chronologically () =
  let t, _ = scripted_transport ~bars_response:sample_bars_newest_first in
  let cfg = make_cfg () in
  let rest = Rest.make ~transport:t ~cfg in
  let bars = Rest.bars rest ~n:100
    ~symbol:(Symbol.of_string "SBER@TQBR") ~timeframe:H1 in
  let tss = List.map (fun (c : Candle.t) -> c.ts) bars in
  let sorted = List.sort Int64.compare tss in
  Alcotest.(check bool) "ascending by ts" true (tss = sorted);
  Alcotest.(check int) "3 bars decoded" 3 (List.length bars)

let test_bars_decimal_decoded () =
  let t, _ = scripted_transport ~bars_response:sample_bars_newest_first in
  let cfg = make_cfg () in
  let rest = Rest.make ~transport:t ~cfg in
  let bars = Rest.bars rest ~n:100
    ~symbol:(Symbol.of_string "SBER@TQBR") ~timeframe:H1 in
  let last = List.nth bars (List.length bars - 1) in
  Alcotest.(check (float 1e-6)) "last close = 320.5"
    320.5 (Decimal.to_float last.close);
  Alcotest.(check (float 1e-6)) "last volume"
    1500.0 (Decimal.to_float last.volume)

let test_bare_ticker_uses_default_class_code () =
  let t, captured = scripted_transport ~bars_response:sample_bars_newest_first in
  let cfg = Config.make
    ~refresh_token:"R"
    ~rest_base:(Uri.of_string "https://api.test")
    ~token_endpoint:(Uri.of_string "https://api.test/token")
    ~default_class_code:"SPBXM"
    ()
  in
  let rest = Rest.make ~transport:t ~cfg in
  let _ = Rest.bars rest ~n:10
    ~symbol:(Symbol.of_string "AAPL") ~timeframe:H1 in
  let req = !captured in
  Alcotest.(check string) "classCode defaults to config"
    "SPBXM" (Option.value (Uri.get_query_param req.url "classCode")
               ~default:"<missing>");
  Alcotest.(check string) "ticker pass-through"
    "AAPL" (Option.value (Uri.get_query_param req.url "ticker")
              ~default:"<missing>")

let test_bars_caps_n_at_max () =
  let t, captured = scripted_transport ~bars_response:sample_bars_newest_first in
  let cfg = make_cfg () in
  let rest = Rest.make ~transport:t ~cfg in
  let _ = Rest.bars rest ~n:10_000
    ~symbol:(Symbol.of_string "SBER@TQBR") ~timeframe:M1 in
  (* Window = n * tf_seconds; capped to 1440 bars → 1440 minutes. *)
  let start_str = Option.value
    (Uri.get_query_param !captured.url "startDate") ~default:"" in
  let end_str = Option.value
    (Uri.get_query_param !captured.url "endDate") ~default:"" in
  Alcotest.(check bool) "startDate is ISO 8601" true
    (String.length start_str >= 20 && String.get start_str 10 = 'T');
  Alcotest.(check bool) "endDate is ISO 8601" true
    (String.length end_str >= 20)

let tests = [
  "request URL & params",             `Quick, test_bars_request_url_and_params;
  "sorts newest-first to chronological", `Quick, test_bars_sorted_chronologically;
  "decodes plain-float decimals",     `Quick, test_bars_decimal_decoded;
  "bare ticker uses default classCode", `Quick, test_bare_ticker_uses_default_class_code;
  "caps n at 1440",                   `Quick, test_bars_caps_n_at_max;
]
