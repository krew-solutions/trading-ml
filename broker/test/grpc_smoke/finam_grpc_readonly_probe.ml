(** Read-only live verification of the Finam gRPC client against
    [api.finam.ru:443]. Currently in diagnostic mode: it first does two raw
    [Auth] calls on one channel to check sequential HTTP/2 multiplexing, then
    the real {!Finam_grpc.Client} unary RPCs. Per-step timeouts localise a hang.

    Requires [FINAM_SECRET] (+ [FINAM_ACCOUNT_ID]). Not part of [@runtest]. *)

open Core
module A = Finam_grpc_proto.Auth_service.Grpc.Tradeapi.V1.Auth

let pf fmt =
  Printf.ksprintf
    (fun s ->
      print_endline s;
      flush stdout)
    fmt

let timed ~clock ~label ~secs f =
  match Eio.Time.with_timeout clock secs (fun () -> Ok (f ())) with
  | Ok v -> v
  | Error `Timeout ->
      pf "[HANG] %s did not complete within %.0fs" label secs;
      exit 3

let () =
  match Sys.getenv_opt "FINAM_SECRET" with
  | None | Some "" -> pf "[SKIP] FINAM_SECRET not set."
  | Some secret ->
      let account_id =
        match Sys.getenv_opt "FINAM_ACCOUNT_ID" with
        | Some s -> s
        | None -> ""
      in
      Eio_main.run @@ fun env ->
      Mirage_crypto_rng_unix.use_default ();
      let clock = Eio.Stdenv.clock env in
      Eio.Switch.run @@ fun sw ->
      (* --- diagnostic: two raw Auth calls on ONE channel --- *)
      pf "[..] connecting to api.finam.ru:443";
      let ch = Finam_grpc.Channel.connect ~sw ~env ~host:"api.finam.ru" ~port:443 in
      pf "[ok] connected";
      let raw_auth label =
        let req =
          A.AuthRequest.make ~secret () |> A.AuthService.Auth.Request.to_proto
          |> Ocaml_protoc_plugin.Writer.contents
        in
        let bytes =
          timed ~clock ~label ~secs:20.0 (fun () ->
              Finam_grpc.Channel.unary ch ~rpc:A.AuthService.Auth.name ~metadata:[]
                ~request:req)
        in
        match
          A.AuthService.Auth.Response.from_proto (Ocaml_protoc_plugin.Reader.create bytes)
        with
        | Ok t -> pf "[ok] %s → JWT length %d" label (String.length t)
        | Error _ -> pf "[warn] %s decode error" label
      in
      raw_auth "raw Auth #1";
      raw_auth "raw Auth #2 (same channel)";
      Finam_grpc.Channel.shutdown ch;

      (* --- real client unary RPCs --- *)
      let cfg = Finam_grpc.Config.make ~secret () in
      let client = Finam_grpc.Client.create ~env cfg in
      Finam_grpc.Client.set_switch client sw;
      let venues =
        timed ~clock ~label:"exchanges" ~secs:20.0 (fun () ->
            Finam_grpc.Client.exchanges client)
      in
      pf "[ok] exchanges: %d venues (e.g. %s)" (List.length venues)
        (match venues with
        | v :: _ -> Mic.to_string v
        | [] -> "-");
      let instrument = Instrument.of_qualified "SBER@MISX" in
      let bars =
        timed ~clock ~label:"bars" ~secs:20.0 (fun () ->
            Finam_grpc.Client.bars client ~n:5 ~instrument ~timeframe:Timeframe.M1)
      in
      (match List.rev bars with
      | last :: _ ->
          pf "[ok] bars SBER@MISX M1: %d bars, last close=%s" (List.length bars)
            (Decimal.to_string last.close)
      | [] -> pf "[warn] bars empty (market closed?)");
      if account_id <> "" then begin
        let orders =
          timed ~clock ~label:"get_orders" ~secs:20.0 (fun () ->
              Finam_grpc.Client.get_orders client ~account_id)
        in
        pf "[ok] get_orders: %d order(s)" (List.length orders);
        let trades =
          timed ~clock ~label:"account_trades" ~secs:20.0 (fun () ->
              Finam_grpc.Client.account_trades client ~account_id)
        in
        pf "[ok] account_trades (24h): %d trade(s)" (List.length trades)
      end;
      pf "[done] read-only gRPC verification complete";
      (* The client's channel keeps a background HTTP/2 fiber alive under [sw];
         this is correct for a long-running host but means [Switch.run] would
         otherwise block here. A probe just exits. *)
      exit 0
