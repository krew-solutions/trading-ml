(** Live smoke tests against the real BCS Trade API.

    Skipped silently when credentials are absent so the file can
    live in the tree without tripping CI. Run manually during a
    trading session with credentials exported:

    {v
    export BCS_SECRET=<refresh_token from BCS portal>    # first run only
    dune build @live_smoke
    v}

    BCS doesn't expose account_id in request paths — it's implicit
    in the OAuth2 token — so we don't require a matching env var.
    Client orders are correlated via [clientOrderId], which is also
    the broker-side id (unlike Finam which keeps a separate
    [order_id]); the adapter's [Rest.get_order] expects that
    [clientOrderId] and [get_deals] ties executions back through
    the [orderNum] echoed on each deal.

    Refresh-token persistence: Keycloak rotates on every exchange.
    After the first run the rotated token lives in
    [/tmp/trading-bcs-smoke-refresh] (chmod 0o600); subsequent runs
    read from there, so the env var is only needed once to bootstrap.
    Delete the file to force re-bootstrap from env. *)

open Core

let refresh_token_file = "/tmp/trading-bcs-smoke-refresh"

let token_store () =
  Token_store.fallback
    (Token_store.file ~path:refresh_token_file)
    (Token_store.env ~name:"BCS_SECRET")

let skip_unless_creds () =
  match Token_store.load (token_store ()) with
  | Some _ -> ()
  | None ->
      Printf.printf "  [SKIP] BCS_SECRET not set and %s absent\n%!" refresh_token_file;
      raise Exit

let make_rest ~env =
  let cfg = Bcs.Config.make () in
  let transport = Http_transport.make_eio ~env in
  Bcs.Rest.make ~transport ~cfg ~token_store:(token_store ())

let sber =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX")
    ~board:(Board.of_string "TQBR") ()

(** Baseline: auth round-trip works, bars decode, the orders and
    deals lists decode even when the account is idle. Printing
    counts rather than asserting nonzero keeps the test robust when
    the account has no history. *)
let test_auth_bars_orders_deals () =
  try
    skip_unless_creds ();
    Eio_main.run @@ fun env ->
    Mirage_crypto_rng_unix.use_default ();
    let rest = make_rest ~env in
    let bars = Bcs.Rest.bars rest ~n:10 ~instrument:sber ~timeframe:Timeframe.H1 in
    Alcotest.(check bool) "got at least one bar" true (List.length bars > 0);
    let orders = Bcs.Rest.get_orders rest in
    Printf.printf "  [info] %d open orders\n%!" (List.length orders);
    let deals = Bcs.Rest.get_deals rest in
    Printf.printf "  [info] %d deals in window\n%!" (List.length deals)
  with Exit -> ()

(** Full order lifecycle: place → get → deals filter → cancel.
    Same pricing waterfall as the Finam smoke (0.95 → band floor →
    0.98) to stay inside MOEX's per-instrument price bands. The
    placed order is a 1-lot limit BUY on SBER well below market,
    cancelled in [Fun.protect]'s [finally] even if an intermediate
    assert fails. *)
let test_limit_order_lifecycle () =
  try
    skip_unless_creds ();
    Eio_main.run @@ fun env ->
    Mirage_crypto_rng_unix.use_default ();
    let rest = make_rest ~env in
    let bars = Bcs.Rest.bars rest ~n:1 ~instrument:sber ~timeframe:Timeframe.H1 in
    let last_close =
      match List.rev bars with
      | c :: _ -> Decimal.to_float c.Candle.close
      | [] -> failwith "no bars to anchor limit price"
    in
    let snap px = Decimal.of_float (Float.round (px *. 100.0) /. 100.0) in
    (* BCS accepts UUID-style client ids, including dashes. Use a
         stable "smokeN" prefix so partial runs are easy to spot in
         the orders list. *)
    (* Exercise the adapter's own cid generator — BCS's
         [generate_client_order_id] owns the wire-format rule
         (UUIDv4 with dashes), and the smoke test is how we
         verify that contract end-to-end. *)
    let broker = Bcs.Bcs_broker.as_broker rest in
    let cid = Broker.generate_client_order_id broker in
    let place_at px =
      Bcs.Rest.create_order rest ~instrument:sber ~side:Side.Buy ~quantity:1
        ~kind:(Order.Limit px) ~client_order_id:cid ()
    in
    let try_place px = try Ok (place_at px) with Failure msg -> Error msg in
    Printf.printf "  [info] last H1 close = %.2f\n%!" last_close;
    let placed =
      match try_place (snap (last_close *. 0.95)) with
      | Ok o -> o
      | Error msg1 -> (
          Printf.printf "  [info] 0.95 attempt rejected: %s\n%!" msg1;
          let re = Str.regexp "less than \\([0-9]+\\.?[0-9]*\\)" in
          let band_min =
            try
              ignore (Str.search_forward re msg1 0);
              Some (float_of_string (Str.matched_group 1 msg1))
            with Not_found -> None
          in
          match band_min with
          | Some floor -> (
              Printf.printf "  [info] retry at band floor %.2f\n%!" floor;
              match try_place (snap floor) with
              | Ok o -> o
              | Error m -> failwith m)
          | None -> (
              Printf.printf "  [info] retry at 0.98 fallback\n%!";
              match try_place (snap (last_close *. 0.98)) with
              | Ok o -> o
              | Error m -> failwith m))
    in
    Printf.printf "  [info] placed cid=%s status=%s\n%!" cid
      (Order.status_to_string placed.status);
    Fun.protect
      ~finally:(fun () ->
        try
          let cancelled = Bcs.Rest.cancel_order rest ~client_order_id:cid in
          Printf.printf "  [info] cancelled cid=%s status=%s\n%!" cid
            (Order.status_to_string cancelled.status)
        with e ->
          Printf.printf "  [warn] cancel failed for %s: %s\n%!" cid (Printexc.to_string e))
      (fun () ->
        Alcotest.(check string)
          "round-trip cid on place response" cid placed.client_order_id;
        (* BCS identifies orders by clientOrderId directly. *)
        let fetched = Bcs.Rest.get_order rest ~client_order_id:cid in
        Alcotest.(check string) "round-trip cid on get" cid fetched.client_order_id;
        (* Deals are keyed by [orderNum] which we find in
             [exec_id] on the fetched order. If the server hasn't
             assigned an [exec_id] yet (still pending), there
             definitely can't be executions either. *)
        let our_deals =
          if fetched.exec_id = "" then []
          else
            Bcs.Rest.get_deals rest
            |> List.filter_map (fun (order_num, exec) ->
                if order_num = fetched.exec_id then Some exec else None)
        in
        Alcotest.(check int)
          "no executions on far-from-market limit" 0 (List.length our_deals))
  with Exit -> ()

let tests =
  [
    ("auth + bars + orders + deals", `Quick, test_auth_bars_orders_deals);
    ("limit order lifecycle", `Quick, test_limit_order_lifecycle);
  ]
