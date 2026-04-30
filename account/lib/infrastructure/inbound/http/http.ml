open Core

type market_price_port = instrument:Instrument.t -> float

type place_order_request = {
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  kind : Order.kind;
}
(** Parsed wire-format for [POST /api/orders] as Account needs it.
    {!Order.time_in_force} and [client_order_id] are part of the
    same JSON payload but Account does not consume them — they
    belong to {!Broker_commands.Submit_order_command.t}. They will
    be parsed by the broker BC's inbound HTTP module (or threaded
    through a saga message) when the place-order saga is fully
    wired. *)

(** Accept either JSON int or float for numeric fields — UI uses float,
    CLI may send ints for lot-sized quantities. *)
let to_decimal (j : Yojson.Safe.t) : Decimal.t =
  match j with
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s | `String s -> Decimal.of_string s
  | _ -> failwith "expected number"

let place_order_of_json (j : Yojson.Safe.t) : place_order_request =
  let open Yojson.Safe.Util in
  let symbol = j |> member "symbol" |> to_string in
  let side =
    match j |> member "side" |> to_string |> String.uppercase_ascii with
    | "BUY" -> Side.Buy
    | "SELL" -> Side.Sell
    | s -> failwith ("unknown side: " ^ s)
  in
  let quantity = to_decimal (member "quantity" j) in
  let kind_obj = member "kind" j in
  let kind_type =
    match kind_obj with
    | `String s -> String.uppercase_ascii s (* short form: "MARKET" *)
    | _ -> kind_obj |> member "type" |> to_string |> String.uppercase_ascii
  in
  let field_decimal name =
    let f = member name kind_obj in
    if f = `Null then failwith ("missing " ^ name) else to_decimal f
  in
  let kind : Order.kind =
    match kind_type with
    | "MARKET" -> Market
    | "LIMIT" -> Limit (field_decimal "price")
    | "STOP" -> Stop (field_decimal "price")
    | "STOP_LIMIT" ->
        Stop_limit
          { stop = field_decimal "stop_price"; limit = field_decimal "limit_price" }
    | other -> failwith ("unknown kind: " ^ other)
  in
  { instrument = Instrument.of_qualified symbol; side; quantity; kind }

(** Project a parsed [place_order_request] into a
    {!Account_commands.Reserve_command.t}. The [price] is the
    cash-impact reference for reservation: prefer the kind's own
    target price (limit / stop) when present; for market orders
    the composition root's [market_price] port supplies the latest
    mark. *)
let to_reserve_command (market_price : market_price_port) (req : place_order_request) :
    Account_commands.Reserve_command.t =
  let price =
    match req.kind with
    | Limit p | Stop p -> Decimal.to_float p
    | Stop_limit { limit; _ } -> Decimal.to_float limit
    | Market -> market_price ~instrument:req.instrument
  in
  {
    side = Side.to_string req.side;
    symbol = Instrument.to_qualified req.instrument;
    quantity = Decimal.to_float req.quantity;
    price;
  }

let make_handler ~reserve_bus ~market_price : Inbound_http.Route.handler =
 fun request body ->
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  match (meth, path) with
  | `POST, "/api/orders" ->
      let body_str = Eio.Flow.read_all body in
      let req = place_order_of_json (Yojson.Safe.from_string body_str) in
      Bus.Command_bus.send reserve_bus (to_reserve_command market_price req);
      (* TODO: reservation_id is not synchronously knowable on the
         async bus — outcomes will arrive on integration-event
         channels, not back through [send]. The Submit dispatch
         and the HTTP response shape need a proper saga key
         (HTTP-generated correlation_id) and an SSE-driven
         UI flow. Placeholder 202 returned for now. *)
      Some
        ( 202,
          `Response
            (Inbound_http.Response.json ~status:`Accepted
               (`Assoc [ ("status", `String "accepted") ])) )
  | _ -> None
