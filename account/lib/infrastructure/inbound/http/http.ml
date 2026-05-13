open Core

type market_price_port = instrument:Instrument.t -> Decimal.t

type place_order_request = {
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  kind : Account_inbound_queries.Order_kind_view_model.t;
}
(** Parsed wire-format for [POST /api/orders] as Account needs it.
    [time_in_force] and [client_order_id] are part of the same JSON
    payload but Account does not consume them — they belong to the
    broker BC's submit path and will be parsed by the broker BC's
    inbound HTTP module (or threaded through a saga message) when
    the place-order saga is fully wired.

    The [kind] field uses the BC-local wire DTO
    {!Account_inbound_queries.Order_kind_view_model} instead of
    reaching into the broker's typed [Order.kind]: Account is
    cash-bounded by [price] regardless of the order's venue
    semantics, so a string-typed wire-format representation is
    sufficient and keeps the BC self-contained. *)

(** Accept either JSON int or float for numeric fields — UI uses float,
    CLI may send ints for lot-sized quantities. *)
let to_decimal (j : Yojson.Safe.t) : Decimal.t =
  match j with
  | `Int n -> Decimal.of_int n
  | `Float f -> Decimal.of_float f
  | `Intlit s | `String s -> Decimal.of_string s
  | _ -> failwith "expected number"

(** Coerce a "decimalish" JSON value to a string for the wire DTO.
    Numbers are normalised through [Decimal] to match the canonical
    string form used everywhere on the bus. *)
let to_decimal_string_opt (j : Yojson.Safe.t) : string option =
  match j with
  | `Null -> None
  | `String s -> Some s
  | `Int _ | `Float _ | `Intlit _ -> Some (Decimal.to_string (to_decimal j))
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
  let price_field name =
    match kind_obj with
    | `String _ -> None
    | _ -> to_decimal_string_opt (member name kind_obj)
  in
  let kind : Account_inbound_queries.Order_kind_view_model.t =
    {
      type_ = kind_type;
      price = price_field "price";
      stop_price = price_field "stop_price";
      limit_price = price_field "limit_price";
    }
  in
  { instrument = Instrument.of_qualified symbol; side; quantity; kind }

(** Project a parsed [place_order_request] into a
    {!Account_commands.Reserve_command.t}. The [price] is the
    cash-impact reference for reservation: prefer the kind's own
    target price (limit / stop) when present; for market orders
    the composition root's [market_price] port supplies the latest
    mark. *)
let to_reserve_command
    ~(correlation_id : string)
    (market_price : market_price_port)
    (req : place_order_request) : Account_commands.Reserve_command.t =
  let kind = req.kind in
  let require name = function
    | Some s -> s
    | None -> failwith ("missing " ^ name)
  in
  let price =
    match kind.type_ with
    | "MARKET" -> Decimal.to_string (market_price ~instrument:req.instrument)
    | "LIMIT" -> require "price" kind.price
    | "STOP" -> require "price" kind.price
    | "STOP_LIMIT" -> require "limit_price" kind.limit_price
    | other -> failwith ("unknown kind: " ^ other)
  in
  {
    correlation_id;
    side = Side.to_string req.side;
    symbol = Instrument.to_qualified req.instrument;
    quantity = Decimal.to_string req.quantity;
    price;
  }

let make_handler ~dispatch_reserve ~market_price : Inbound_http.Route.handler =
 fun request body ->
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  match (meth, path) with
  | `POST, "/api/orders" ->
      let body_str = Eio.Flow.read_all body in
      let req = place_order_of_json (Yojson.Safe.from_string body_str) in
      let correlation_id = Correlation_id.to_string (Correlation_id.generate ()) in
      dispatch_reserve (to_reserve_command ~correlation_id market_price req);
      (* The cid is the saga-instance key minted here — the future
         Place_order_pm Process Manager will key its instance store
         off this id, and an SSE channel filtered by cid will surface
         the eventual outcome to the client. *)
      Some
        ( 202,
          `Response
            (Inbound_http.Response.json ~status:`Accepted
               (`Assoc
                  [
                    ("status", `String "accepted");
                    ("correlation_id", `String correlation_id);
                  ])) )
  | _ -> None
