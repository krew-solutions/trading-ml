(** Adapter: exposes [Finam.Rest.t] through the broker-agnostic
    [Broker.S] interface. All Finam-specific translation lives here so
    callers (server, CLI, tests) program against [Broker.client].

    [account_id] is baked into the adapter at construction so the port
    stays account-agnostic (a Finam user with multiple accounts creates
    one [Broker.client] per account).

    Finam addresses individual orders by its own server-assigned id,
    while the [Broker.S] port speaks [client_order_id]. The adapter
    keeps an in-memory [client_order_id → server_id] map populated on
    [place_order]; lookups for orders not in the cache fall back to
    scanning [GET /orders] so the mapping survives adapter restarts as
    long as Finam still holds the order. *)

open Core

type t = {
  rest : Rest.t;
  account_id : string;
  srv_by_cid : (string, string) Hashtbl.t;
  mutex : Eio.Mutex.t;
}

let name = "finam"

let make ~account_id (rest : Rest.t) : t =
  { rest; account_id; srv_by_cid = Hashtbl.create 16; mutex = Eio.Mutex.create () }

let bars t ~n ~instrument ~timeframe = Rest.bars t.rest ~n ~instrument ~timeframe

(** Decode Finam's [/v1/exchanges] payload into MIC codes. We drop the
    [name] field — display labels are the UI's concern, not the
    adapter's. Any malformed MIC is silently filtered (Finam has shipped
    placeholder rows in the past). *)
let venues t : Mic.t list =
  let j = Rest.exchanges t.rest in
  match Yojson.Safe.Util.member "exchanges" j with
  | `List items ->
      List.filter_map
        (fun item ->
          match Yojson.Safe.Util.member "mic" item with
          | `String m -> ( try Some (Mic.of_string m) with Invalid_argument _ -> None)
          | _ -> None)
        items
  | _ -> []

let remember t ~client_order_id ~server_id =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.replace t.srv_by_cid client_order_id server_id)

let resolve_server_id t ~client_order_id =
  let cached =
    Eio.Mutex.use_ro t.mutex (fun () -> Hashtbl.find_opt t.srv_by_cid client_order_id)
  in
  match cached with
  | Some id -> id
  | None -> (
      let orders = Rest.get_orders t.rest ~account_id:t.account_id in
      match List.find_opt (fun o -> o.Order.client_order_id = client_order_id) orders with
      | Some o ->
          remember t ~client_order_id ~server_id:o.id;
          o.id
      | None ->
          failwith
            (Printf.sprintf "finam: no order with client_order_id=%s" client_order_id))

let place_order t ~instrument ~side ~quantity ~kind ~tif ~client_order_id =
  let o =
    Rest.place_order t.rest ~account_id:t.account_id ~instrument ~side ~quantity ~kind
      ~tif ~client_order_id ()
  in
  remember t ~client_order_id ~server_id:o.id;
  o

let get_orders t = Rest.get_orders t.rest ~account_id:t.account_id

let get_order t ~client_order_id =
  let server_id = resolve_server_id t ~client_order_id in
  Rest.get_order t.rest ~account_id:t.account_id ~order_id:server_id

let cancel_order t ~client_order_id =
  let server_id = resolve_server_id t ~client_order_id in
  Rest.cancel_order t.rest ~account_id:t.account_id ~order_id:server_id

(** Project account-wide trades into per-execution records for
    the order identified by [client_order_id]. Pulls the
    broker-assigned server id from the cid map (or [GET /orders]
    fallback), then filters [Rest.get_trades] by that id.
    Returns [] if the order has no executions yet (broker holds
    it in the book but hasn't filled). *)
let get_executions t ~client_order_id =
  let server_id = resolve_server_id t ~client_order_id in
  Rest.get_trades t.rest ~account_id:t.account_id
  |> List.filter_map (fun (at : Dto.account_trade) ->
      if at.order_id = server_id then Some at.execution else None)

(** UUID v4 with dashes stripped. Finam's REST validator returns
    400 on dashes ("letters, numbers and space" only), and 32 hex
    digits comfortably satisfy that rule while retaining full UUIDv4
    collision resistance. *)
let generate_client_order_id _ =
  let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
  String.concat "" (String.split_on_char '-' uuid)

let as_broker (t : t) : Broker.client =
  Broker.make
    (module struct
      type nonrec t = t
      let name = name
      let bars = bars
      let venues = venues
      let place_order = place_order
      let get_orders = get_orders
      let get_order = get_order
      let cancel_order = cancel_order
      let get_executions = get_executions
      let generate_client_order_id = generate_client_order_id
    end)
    t
