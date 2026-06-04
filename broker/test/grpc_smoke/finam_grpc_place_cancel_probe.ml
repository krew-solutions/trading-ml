(** Live place/cancel verification of the Finam gRPC adapter against
    [api.finam.ru:443], driven through the real {!Finam_grpc.Finam_grpc_broker}
    [Broker.S] path (placement store + order_id resolution).

    {b Places a real order on the live account.} To keep it non-filling yet
    {e accepted} (so the cancel path is actually exercised), it places a limit
    BUY ~10% below the live last price: a buy below the ask never crosses, and
    10% stays inside MOEX's price band so the order rests as NEW rather than
    being band-rejected. It is cancelled immediately.

    Requires [FINAM_SECRET] + [FINAM_ACCOUNT_ID]. Skips cleanly otherwise. Not
    part of [@runtest]. *)

open Core
module Order = Broker_domain.Order

let pf fmt =
  Printf.ksprintf
    (fun s ->
      print_endline s;
      flush stdout)
    fmt

let () =
  match (Sys.getenv_opt "FINAM_SECRET", Sys.getenv_opt "FINAM_ACCOUNT_ID") with
  | (None | Some ""), _ | _, (None | Some "") ->
      pf "[SKIP] FINAM_SECRET and FINAM_ACCOUNT_ID required."
  | Some secret, Some account_id ->
      Eio_main.run @@ fun env ->
      Mirage_crypto_rng_unix.use_default ();
      Eio.Switch.run @@ fun sw ->
      let cfg = Finam_grpc.Config.make ~secret () in
      let client = Finam_grpc.Client.create ~env cfg in
      Finam_grpc.Client.set_switch client sw;
      let adapter = Finam_grpc.Finam_grpc_broker.make ~account_id client in
      let instrument = Instrument.of_qualified "SBER@MISX" in

      (* Live reference price for the (non-filling, in-band) limit below. *)
      let last =
        match
          List.rev
            (Finam_grpc.Client.bars client ~n:5 ~instrument ~timeframe:Timeframe.M1)
        with
        | c :: _ -> Decimal.to_float c.close
        | [] -> 0.0
      in
      if last <= 0.0 then pf "[abort] no live price for SBER@MISX (market closed?)"
      else begin
        (* ~5% below market: below the ask (so it rests, doesn't cross) yet
           inside MOEX's price band (the floor sits ~8-9% below intraday). *)
        let price = Decimal.of_string (Printf.sprintf "%.2f" (last *. 0.95)) in
        let placement_id = int_of_float (Unix.gettimeofday ()) mod 1_000_000_000 in
        pf "[..] placing LIMIT BUY 1 SBER@MISX @ %s (market ~%.2f), placement_id=%d"
          (Decimal.to_string price) last placement_id;
        let placed =
          Finam_grpc.Finam_grpc_broker.place_order adapter ~placement_id ~instrument
            ~side:Buy ~quantity:(Decimal.of_int 1) ~kind:(Order.Limit price)
            ~tif:Order.DAY
        in
        pf "[ok] place_order → status=%s" (Order.status_to_string placed.status);

        (match Finam_grpc.Finam_grpc_broker.get_order adapter ~placement_id with
        | Some o -> pf "[ok] get_order → status=%s" (Order.status_to_string o.status)
        | None -> pf "[warn] get_order → None");

        (match Finam_grpc.Finam_grpc_broker.cancel_order adapter ~placement_id with
        | Some o -> pf "[ok] cancel_order → status=%s" (Order.status_to_string o.status)
        | None -> pf "[warn] cancel_order → None (no placement recorded)");

        (match Finam_grpc.Finam_grpc_broker.get_order adapter ~placement_id with
        | Some o ->
            pf "[ok] get_order after cancel → status=%s" (Order.status_to_string o.status)
        | None -> pf "[warn] get_order after cancel → None");
        pf "[done] place/cancel verification complete"
      end;
      exit 0
