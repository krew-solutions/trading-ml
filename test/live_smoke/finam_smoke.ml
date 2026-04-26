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
  match (Sys.getenv_opt "FINAM_SECRET", Sys.getenv_opt "FINAM_ACCOUNT_ID") with
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

let sber =
  Instrument.make ~ticker:(Ticker.of_string "SBER") ~venue:(Mic.of_string "MISX") ()

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
        let bars = Finam.Rest.bars rest ~n:10 ~instrument:sber ~timeframe:Timeframe.H1 in
        Alcotest.(check bool) "got at least one bar" true (List.length bars > 0);
        (* get_orders must decode without raising even if zero open. *)
        let orders = Finam.Rest.get_orders rest ~account_id:account in
        Printf.printf "  [info] %d open orders\n%!" (List.length orders);
        (* get_trades must decode without raising. *)
        let trades = Finam.Rest.get_trades rest ~account_id:account in
        Printf.printf "  [info] %d historical trades\n%!" (List.length trades)
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
        let bars = Finam.Rest.bars rest ~n:1 ~instrument:sber ~timeframe:Timeframe.H1 in
        let last_close =
          match List.rev bars with
          | c :: _ -> Decimal.to_float c.Candle.close
          | [] -> failwith "no bars to anchor limit price"
        in
        (* Pricing strategy: pick a BUY-limit price that's safely inside
         MOEX's per-instrument price bands but far enough below market
         to stay unfilled for the few seconds this test runs.

         Attempt 1: [last_close * 0.95] — works on liquid names with
           wide bands (SBER most sessions).
         Attempt 2: if Finam returns "price can not be less than N",
           parse N and retry at that band floor. The placed order
           sits at the extreme of what the exchange accepts.
         Attempt 3: if the first error has no parseable floor
           (e.g. a bare "Invalid value for field: Price" during
           volatile opens), fall back to [last_close * 0.98]. Still
           below market, still rarely triggers a fill.

         SBER quotes in kopecks so every candidate is snapped to
         0.01 before sending. *)
        let snap px = Decimal.of_float (Float.round (px *. 100.0) /. 100.0) in
        (* Finam's client_order_id filter allows letters, digits and
         spaces only — no dashes or underscores. *)
        let cid = Printf.sprintf "smoke%d" (int_of_float (Unix.gettimeofday ())) in
        let place_at px =
          Finam.Rest.place_order rest ~account_id:account ~instrument:sber ~side:Side.Buy
            ~quantity:(Decimal.of_int 1) ~kind:(Order.Limit px) ~tif:Order.DAY
            ~client_order_id:cid ()
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
        let server_id = placed.Order.id in
        Printf.printf "  [info] placed cid=%s server=%s status=%s\n%!" cid server_id
          (Order.status_to_string placed.status);
        (* Always cancel, even if a subsequent assert fails. Leaving a
         live limit hanging against the account is worse than a noisy
         cancel. *)
        Fun.protect
          ~finally:(fun () ->
            try
              let cancelled =
                Finam.Rest.cancel_order rest ~account_id:account ~order_id:server_id
              in
              Printf.printf "  [info] cancelled cid=%s status=%s\n%!" cid
                (Order.status_to_string cancelled.status)
            with e ->
              Printf.printf "  [warn] cancel failed for %s: %s\n%!" server_id
                (Printexc.to_string e))
          (fun () ->
            Alcotest.(check bool) "server assigned an id" true (server_id <> "");
            let fetched =
              Finam.Rest.get_order rest ~account_id:account ~order_id:server_id
            in
            Alcotest.(check string) "round-trip cid" cid fetched.client_order_id;
            let trades = Finam.Rest.get_trades rest ~account_id:account in
            let our_trades =
              List.filter
                (fun (t : Finam.Dto.account_trade) -> t.order_id = server_id)
                trades
            in
            Alcotest.(check int)
              "no executions on far-from-market limit" 0 (List.length our_trades))
  with Exit -> ()

let tests =
  [
    ("auth + bars + account + trades", `Quick, test_auth_bars_account);
    ("limit order lifecycle", `Quick, test_limit_order_lifecycle);
  ]
