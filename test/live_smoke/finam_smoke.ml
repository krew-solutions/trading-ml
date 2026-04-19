(** Live smoke tests against the real Finam Trade API.

    Skipped silently when credentials are absent so the file can
    live in the tree without tripping CI. Run manually during a
    trading session with credentials exported:

    {v
    export FINAM_SECRET=<portal secret>
    export FINAM_ACCOUNT_ID=<account id>
    dune build @live_smoke
    v}

    What each scenario exercises is called out in its comment.
    Fix any broker-side divergence by updating ACL DTOs — the
    point of this suite is to catch Finam protocol drift against
    the typed domain surface. *)

open Core

let creds () =
  match
    Sys.getenv_opt "FINAM_SECRET",
    Sys.getenv_opt "FINAM_ACCOUNT_ID"
  with
  | Some s, Some a when s <> "" && a <> "" -> Some (s, a)
  | _ -> None

let skip_unless_creds () =
  match creds () with
  | Some _ -> ()
  | None ->
    Printf.printf "  [SKIP] FINAM_SECRET / FINAM_ACCOUNT_ID not set\n%!";
    raise Exit

let make_rest ~env (secret, account) =
  let cfg = Finam.Config.make ~account_id:account ~secret () in
  let transport = Http_transport.make_eio ~env in
  Finam.Rest.make ~transport ~cfg

let sber = Instrument.make
  ~ticker:(Ticker.of_string "SBER")
  ~venue:(Mic.of_string "MISX") ()

(** Baseline: auth works, bars come back, account is reachable. *)
let test_auth_bars_account () =
  try
    skip_unless_creds ();
    match creds () with
    | None -> ()
    | Some (secret, account) ->
      Eio_main.run @@ fun env ->
      Mirage_crypto_rng_unix.use_default ();
      let rest = make_rest ~env (secret, account) in
      (* Bars round-trip. *)
      let bars = Finam.Rest.bars rest
        ~n:10 ~instrument:sber ~timeframe:Timeframe.H1 in
      Alcotest.(check bool) "got at least one bar"
        true (List.length bars > 0);
      (* get_orders must decode without raising even if zero open. *)
      let orders = Finam.Rest.get_orders rest ~account_id:account in
      Printf.printf "  [info] %d open orders\n%!" (List.length orders);
      (* get_trades must decode without raising. *)
      let trades = Finam.Rest.get_trades rest ~account_id:account in
      Printf.printf "  [info] %d historical trades\n%!"
        (List.length trades)
  with Exit -> ()

(** Full order lifecycle: place → get → trades (expect none) →
    cancel. Uses a limit BUY far below market so the broker
    never fills. Caller responsibility: have a bit of free cash
    in the account. *)
let test_limit_order_lifecycle () =
  try
    skip_unless_creds ();
    match creds () with
    | None -> ()
    | Some (secret, account) ->
      Eio_main.run @@ fun env ->
      Mirage_crypto_rng_unix.use_default ();
      let rest = make_rest ~env (secret, account) in
      (* Pull last price to anchor the limit. *)
      let bars = Finam.Rest.bars rest
        ~n:1 ~instrument:sber ~timeframe:Timeframe.H1 in
      let last_close = match List.rev bars with
        | c :: _ -> Decimal.to_float c.Candle.close
        | [] -> failwith "no bars to anchor limit price" in
      (* 5% below market. Far enough to be practically unfillable in a
         short smoke window, but MOEX's per-instrument price bands can
         be tighter (API returns 400 with the exact minimum allowed
         price). If that happens, retry at the stated floor — still
         unlikely to fill because the market would have to reach the
         lower band inside our window. SBER quotes in kopecks so we
         snap to 0.01. *)
      let snap px =
        Decimal.of_float (Float.round (px *. 100.0) /. 100.0) in
      (* Finam's client_order_id filter allows letters, digits and
         spaces only — no dashes or underscores. *)
      let cid = Printf.sprintf "smoke%d" (int_of_float (Unix.gettimeofday ())) in
      let place_at px =
        let payload = Finam.Dto.place_order_payload
          ~instrument:sber ~side:Side.Buy
          ~quantity:(Decimal.of_int 1) ~kind:(Order.Limit px)
          ~tif:Order.DAY ~client_order_id:cid () in
        let path = Printf.sprintf "/v1/accounts/%s/orders" account in
        let j = Finam.Rest.post_json rest path payload in
        Printf.printf "  [raw place response] %s\n%!"
          (Yojson.Safe.pretty_to_string j);
        Finam.Dto.order_of_json j in
      Printf.printf "  [info] last H1 close = %.2f\n%!" last_close;
      let try_place px =
        Printf.printf "  [info] place attempt at %s\n%!"
          (Decimal.to_string px);
        try Ok (place_at px) with Failure msg -> Error msg in
      let placed =
        match try_place (snap (last_close *. 0.95)) with
        | Ok o -> o
        | Error msg1 ->
          Printf.printf "  [info] first attempt failed: %s\n%!" msg1;
          let re = Str.regexp "less than \\([0-9]+\\.?[0-9]*\\)" in
          let band_min =
            try
              ignore (Str.search_forward re msg1 0);
              Some (float_of_string (Str.matched_group 1 msg1))
            with Not_found -> None
          in
          match band_min with
          | Some floor ->
            (match try_place (snap floor) with
             | Ok o -> o
             | Error m -> failwith m)
          | None ->
            (* No parseable floor — try a gentler offset (-2%). *)
            (match try_place (snap (last_close *. 0.98)) with
             | Ok o -> o
             | Error m -> failwith m)
      in
      let server_id = placed.Order.id in
      Printf.printf "  [info] placed cid=%s server=%s status=%s\n%!"
        cid server_id (Order.status_to_string placed.status);
      (* Always cancel, even if a subsequent assert fails — leaving a
         live limit hanging against the account is worse than a noisy
         cancel. *)
      Fun.protect
        ~finally:(fun () ->
          try
            let cancelled = Finam.Rest.cancel_order rest
              ~account_id:account ~order_id:server_id in
            Printf.printf "  [info] cancelled cid=%s status=%s\n%!"
              cid (Order.status_to_string cancelled.status)
          with e ->
            Printf.printf "  [warn] cancel failed for %s: %s\n%!"
              server_id (Printexc.to_string e))
        (fun () ->
          Alcotest.(check bool) "server assigned an id"
            true (server_id <> "");
          (* Raw GET dump: the previous run's PlaceOrder echoed our
             [client_order_id] correctly, but the subsequent GetOrder
             returned a different value — probe what shape Finam sends
             here. *)
          let get_path = Printf.sprintf
            "/v1/accounts/%s/orders/%s" account server_id in
          let raw_get = Finam.Rest.get_json rest get_path [] in
          Printf.printf "  [raw get response] %s\n%!"
            (Yojson.Safe.pretty_to_string raw_get);
          let fetched = Finam.Dto.order_of_json raw_get in
          Alcotest.(check string) "round-trip cid"
            cid fetched.client_order_id;
          let trades = Finam.Rest.get_trades rest ~account_id:account in
          let our_trades = List.filter
            (fun (t : Finam.Dto.account_trade) -> t.order_id = server_id)
            trades in
          Alcotest.(check int) "no executions on far-from-market limit"
            0 (List.length our_trades))
  with Exit -> ()

let tests = [
  "auth + bars + account + trades", `Quick, test_auth_bars_account;
  "limit order lifecycle",          `Quick, test_limit_order_lifecycle;
]
