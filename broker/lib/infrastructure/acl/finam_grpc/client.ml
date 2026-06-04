(** Finam gRPC client: the single seam between the adapter and the wire.

    Owns one multiplexed gRPC {!Channel.t} (lazily (re)connected) and the JWT
    cache, and exposes the Finam RPCs the broker port needs — unary (bars,
    orders, account trades, exchanges) and server-streaming (bars, public tape,
    own fills). This is the gRPC counterpart of [Finam.Rest] + [Finam.Auth] +
    [Finam.Ws_bridge] fused: gRPC carries both request/response and streaming
    over the same HTTP/2 connection, so there is no separate WS transport.

    Authentication mirrors the REST flow: the portal [secret] is exchanged via
    [AuthService.Auth] for a short-lived JWT (the [Auth] RPC itself is the only
    unauthenticated call); the JWT then rides in the [authorization] metadata of
    every other call, refreshed before its [exp]. *)

open Core
module Pbrt = Ocaml_protoc_plugin
module Auth = Finam_grpc_proto.Auth_service.Grpc.Tradeapi.V1.Auth
module Md = Conv.Md
module Ord = Conv.Ord
module Assets = Finam_grpc_proto.Assets_service.Grpc.Tradeapi.V1.Assets
module Accounts = Finam_grpc_proto.Accounts_service.Grpc.Tradeapi.V1.Accounts

type t = {
  cfg : Config.t;
  env : Eio_unix.Stdenv.base;
  sw : Eio.Switch.t;
  mutex : Eio.Mutex.t;  (** guards [channel] and [jwt] *)
  mutable channel : Channel.t option;
  mutable jwt : (string * float) option;  (** token, expiry (unix epoch s) *)
}

let create ~sw ~env (cfg : Config.t) : t =
  { cfg; env; sw; mutex = Eio.Mutex.create (); channel = None; jwt = None }

let now () = Unix.gettimeofday ()

(* ---- channel lifecycle ------------------------------------------------- *)

(** A live channel, (re)connecting if absent or closed. The mutex is held across
    [Channel.connect] so concurrent first-callers don't open duplicate
    connections; reconnection is rare relative to call volume. *)
let conn t : Channel.t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match t.channel with
      | Some c when not (Channel.is_closed c) -> c
      | _ ->
          let c = Channel.connect ~sw:t.sw ~env:t.env ~host:t.cfg.host ~port:t.cfg.port in
          t.channel <- Some c;
          c)

(* ---- JWT auth ---------------------------------------------------------- *)

(** Decode a JWT's [exp] claim (seconds since epoch). [None] on any parse
    problem; callers fall back to a conservative TTL. Ported from the REST
    sibling's [Finam.Auth]. *)
let decode_exp (token : string) : float option =
  try
    match String.split_on_char '.' token with
    | _ :: payload_b64 :: _ -> (
        let normalise s =
          let s =
            String.map
              (function
                | '-' -> '+'
                | '_' -> '/'
                | c -> c)
              s
          in
          let pad = (4 - (String.length s mod 4)) mod 4 in
          s ^ String.make pad '='
        in
        let raw = Base64.decode_exn (normalise payload_b64) in
        let j = Yojson.Safe.from_string raw in
        match Yojson.Safe.Util.member "exp" j with
        | `Int n -> Some (float_of_int n)
        | `Float f -> Some f
        | _ -> None)
    | _ -> None
  with _ -> None

(** Refresh margin: renew 30 s before the stated expiry. *)
let auth_margin = 30.0

(** Raw [AuthService.Auth] call — no metadata, since this is the call that mints
    the token. Returns the JWT. *)
let fetch_token t : string =
  let c = conn t in
  let req =
    Auth.AuthRequest.make ~secret:t.cfg.secret ~source_app_id:t.cfg.source_app_id ()
  in
  let request = Auth.AuthService.Auth.Request.to_proto req |> Pbrt.Writer.contents in
  let bytes = Channel.unary c ~rpc:Auth.AuthService.Auth.name ~metadata:[] ~request in
  match Auth.AuthService.Auth.Response.from_proto (Pbrt.Reader.create bytes) with
  | Ok token -> token (* AuthResponse collapses to the bare token string *)
  | Error e -> failwith ("finam-grpc: auth response decode: " ^ Pbrt.Result.show_error e)

(** A valid JWT, refreshing through the cache when stale. Concurrent stale
    callers may each refresh; last write wins and all get a valid token —
    cheaper than serialising every caller behind the network round-trip
    (same trade-off as the REST sibling). *)
let token t : string =
  let cached =
    Eio.Mutex.use_ro t.mutex (fun () ->
        match t.jwt with
        | Some (tok, exp) when exp -. now () >= auth_margin -> Some tok
        | _ -> None)
  in
  match cached with
  | Some tok -> tok
  | None ->
      let tok = fetch_token t in
      let exp =
        match decode_exp tok with
        | Some e -> e
        | None -> now () +. 600.0
      in
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> t.jwt <- Some (tok, exp));
      tok

let auth_metadata t = [ ("authorization", token t) ]

(* ---- generic call helpers --------------------------------------------- *)

let unary t ~rpc ~encode ~decode req =
  let metadata = auth_metadata t in
  let c = conn t in
  let request = encode req |> Pbrt.Writer.contents in
  let bytes = Channel.unary c ~rpc ~metadata ~request in
  match decode (Pbrt.Reader.create bytes) with
  | Ok v -> v
  | Error e ->
      failwith (Printf.sprintf "finam-grpc %s decode: %s" rpc (Pbrt.Result.show_error e))

(** Run a server-stream to completion, decoding each frame and feeding the
    decoded payload to [on_message]. Blocks the calling fiber for the stream's
    lifetime; raises {!Channel.Grpc_error} on a non-OK final status. Decode
    failures on a single frame are skipped (defensive, like the REST decoders). *)
let server_streaming t ~rpc ~encode ~decode ~on_message req =
  let metadata = auth_metadata t in
  let c = conn t in
  let request = encode req |> Pbrt.Writer.contents in
  Channel.server_streaming c ~rpc ~metadata ~request ~on_message:(fun bytes ->
      match decode (Pbrt.Reader.create bytes) with
      | Ok v -> on_message v
      | Error _ -> ())

(* ---- unary RPCs -------------------------------------------------------- *)

(** Historical bars. Window defaults to the last [n] timeframe units ending now,
    matching [Finam.Rest.bars]. *)
let bars ?from_ts ?to_ts ?(n = 500) t ~instrument ~timeframe : Candle.t list =
  let now_ts = Int64.of_float (now ()) in
  let tf_secs = Int64.of_int (Timeframe.to_seconds timeframe) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts =
    Option.value from_ts ~default:(Int64.sub end_ts (Int64.mul (Int64.of_int n) tf_secs))
  in
  let req =
    Md.BarsRequest.make
      ~symbol:(Conv.symbol_of_instrument instrument)
      ~timeframe:(Conv.timeframe_to_pb timeframe)
      ~interval:(Conv.interval ~from_ts:start_ts ~to_ts:end_ts)
      ()
  in
  let resp =
    unary t ~rpc:Md.MarketDataService.Bars.name
      ~encode:Md.MarketDataService.Bars.Request.to_proto
      ~decode:Md.MarketDataService.Bars.Response.from_proto req
  in
  List.map Conv.candle_of_bar resp.bars

(** List of venues as MIC codes; malformed MICs are dropped. *)
let exchanges t : Mic.t list =
  (* [ExchangesResponse] has a single field ([exchanges]); the generated type
     collapses to the bare list. *)
  let exchanges =
    unary t ~rpc:Assets.AssetsService.Exchanges.name
      ~encode:Assets.AssetsService.Exchanges.Request.to_proto
      ~decode:Assets.AssetsService.Exchanges.Response.from_proto
      (Assets.ExchangesRequest.make ())
  in
  List.filter_map
    (fun (e : Assets.Exchange.t) ->
      try Some (Mic.of_string e.mic) with Invalid_argument _ -> None)
    exchanges

let place_order t ~account_id ~instrument ~side ~quantity ~kind ~tif ~client_order_id :
    Order_dto.t =
  let req =
    Order_dto.place_request ~account_id ~instrument ~side ~quantity ~kind ~tif
      ~client_order_id
  in
  unary t ~rpc:Ord.OrdersService.PlaceOrder.name
    ~encode:Ord.OrdersService.PlaceOrder.Request.to_proto
    ~decode:Ord.OrdersService.PlaceOrder.Response.from_proto req
  |> Order_dto.of_pb

let cancel_order t ~account_id ~order_id : Order_dto.t =
  let req = Ord.CancelOrderRequest.make ~account_id ~order_id () in
  unary t ~rpc:Ord.OrdersService.CancelOrder.name
    ~encode:Ord.OrdersService.CancelOrder.Request.to_proto
    ~decode:Ord.OrdersService.CancelOrder.Response.from_proto req
  |> Order_dto.of_pb

let get_order t ~account_id ~order_id : Order_dto.t =
  let req = Ord.GetOrderRequest.make ~account_id ~order_id () in
  unary t ~rpc:Ord.OrdersService.GetOrder.name
    ~encode:Ord.OrdersService.GetOrder.Request.to_proto
    ~decode:Ord.OrdersService.GetOrder.Response.from_proto req
  |> Order_dto.of_pb

let get_orders t ~account_id : Order_dto.t list =
  let req = Ord.OrdersRequest.make ~account_id () in
  (* [OrdersResponse] is single-field ([orders]) → collapsed to a bare list. *)
  let orders =
    unary t ~rpc:Ord.OrdersService.GetOrders.name
      ~encode:Ord.OrdersService.GetOrders.Request.to_proto
      ~decode:Ord.OrdersService.GetOrders.Response.from_proto req
  in
  List.map Order_dto.of_pb orders

(** Account-wide execution history for [(from_ts, to_ts)] (default: last 24 h),
    as raw [AccountTrade]s; the broker filters / lifts them. Mirrors
    [Finam.Rest.get_trades]. *)
let account_trades ?from_ts ?to_ts t ~account_id : Conv.Pb_account_trade.t list =
  let now_ts = Int64.of_float (now ()) in
  let end_ts = Option.value to_ts ~default:now_ts in
  let start_ts = Option.value from_ts ~default:(Int64.sub end_ts 86_400L) in
  let req =
    Accounts.TradesRequest.make ~account_id ~limit:0
      ~interval:(Conv.interval ~from_ts:start_ts ~to_ts:end_ts)
      ()
  in
  (* [TradesResponse] is single-field ([trades]) → collapsed to a bare list. *)
  unary t ~rpc:Accounts.AccountsService.Trades.name
    ~encode:Accounts.AccountsService.Trades.Request.to_proto
    ~decode:Accounts.AccountsService.Trades.Response.from_proto req

(* ---- server-streaming RPCs -------------------------------------------- *)

(** Subscribe to aggregated bars for [(instrument, timeframe)]. [on_bar] fires
    per bar update. Blocks until the stream ends. *)
let subscribe_bars t ~instrument ~timeframe ~on_bar : unit =
  let req =
    Md.SubscribeBarsRequest.make
      ~symbol:(Conv.symbol_of_instrument instrument)
      ~timeframe:(Conv.timeframe_to_pb timeframe)
      ()
  in
  server_streaming t ~rpc:Md.MarketDataService.SubscribeBars.name
    ~encode:Md.MarketDataService.SubscribeBars.Request.to_proto
    ~decode:Md.MarketDataService.SubscribeBars.Response.from_proto
    ~on_message:(fun (resp : Md.SubscribeBarsResponse.t) ->
      List.iter (fun b -> on_bar (Conv.candle_of_bar b)) resp.bars)
    req

(** Subscribe to the public trade tape for [instrument]. [on_trade] fires per
    raw {!Conv.Md.Trade} (the broker lifts and dedups it — it needs the wire
    [trade_id] for high-water dedup across re-subscribes). Blocks until the
    stream ends. This is the native gRPC spot tape — the feed the REST sibling
    has to poll because Finam's WS only stubbed spot. *)
let subscribe_latest_trades t ~instrument ~on_trade : unit =
  let req =
    Md.SubscribeLatestTradesRequest.make ~symbol:(Conv.symbol_of_instrument instrument) ()
  in
  server_streaming t ~rpc:Md.MarketDataService.SubscribeLatestTrades.name
    ~encode:Md.MarketDataService.SubscribeLatestTrades.Request.to_proto
    ~decode:Md.MarketDataService.SubscribeLatestTrades.Response.from_proto
    ~on_message:(fun (resp : Md.SubscribeLatestTradesResponse.t) ->
      List.iter on_trade resp.trades)
    req

(** Subscribe to this account's own fills. [on_trade] fires per [AccountTrade]
    (raw — the broker resolves [order_id → placement_id] and lifts it). Blocks
    until the stream ends. *)
let subscribe_trades t ~account_id ~on_trade : unit =
  let req = Ord.SubscribeTradesRequest.make ~account_id () in
  server_streaming t ~rpc:Ord.OrdersService.SubscribeTrades.name
    ~encode:Ord.OrdersService.SubscribeTrades.Request.to_proto
    ~decode:Ord.OrdersService.SubscribeTrades.Response.from_proto
      (* [SubscribeTradesResponse] is single-field ([trades]) → bare list. *)
    ~on_message:(fun (trades : Conv.Pb_account_trade.t list) -> List.iter on_trade trades)
    req
