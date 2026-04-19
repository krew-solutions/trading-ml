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
         short smoke window, but inside MOEX's per-instrument price
         bands (a 20% offset trips the "price can not be less than X"
         guard). SBER quotes in kopecks, so snap to 0.01. *)
      let limit_px = Decimal.of_float
        (Float.round (last_close *. 0.95 *. 100.0) /. 100.0) in
      (* Finam's client_order_id filter allows letters, digits and
         spaces only — no dashes or underscores. *)
      let cid = Printf.sprintf "smoke%d" (int_of_float (Unix.gettimeofday ())) in
      let placed = Finam.Rest.place_order rest
        ~account_id:account ~instrument:sber
        ~side:Side.Buy ~quantity:(Decimal.of_int 1)
        ~kind:(Order.Limit limit_px) ~tif:Order.DAY
        ~client_order_id:cid () in
      let server_id = placed.Order.id in
      Printf.printf "  [info] placed cid=%s server=%s status=%s\n%!"
        cid server_id (Order.status_to_string placed.status);
      Alcotest.(check bool) "server assigned an id"
        true (server_id <> "");
      (* Confirm it's retrievable. *)
      let fetched = Finam.Rest.get_order rest
        ~account_id:account ~order_id:server_id in
      Alcotest.(check string) "round-trip cid"
        cid fetched.client_order_id;
      (* Expect zero trades for this just-placed order. *)
      let trades = Finam.Rest.get_trades rest ~account_id:account in
      let our_trades = List.filter
        (fun (t : Finam.Dto.account_trade) -> t.order_id = server_id) trades in
      Alcotest.(check int) "no executions on far-from-market limit"
        0 (List.length our_trades);
      (* Clean up. *)
      let cancelled = Finam.Rest.cancel_order rest
        ~account_id:account ~order_id:server_id in
      Printf.printf "  [info] cancelled cid=%s status=%s\n%!"
        cid (Order.status_to_string cancelled.status)
  with Exit -> ()

let tests = [
  "auth + bars + account + trades", `Quick, test_auth_bars_account;
  "limit order lifecycle",          `Quick, test_limit_order_lifecycle;
]
