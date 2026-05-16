(** Adapter: exposes [Finam.Rest.t] through the broker-agnostic
    [Broker.S] interface. All Finam-specific translation lives here so
    callers (server, CLI, tests) program against [Broker.client].

    [account_id] is baked into the adapter at construction so the port
    stays account-agnostic (a Finam user with multiple accounts creates
    one [Broker.client] per account).

    {b Order identity at the port.} The placement-keyed methods
    speak [placement_id : int]. The adapter mints a Finam-format
    [client_order_id] (32 hex digits — Finam's validator rejects
    dashes) on submit and records [(placement_id ↦
    client_order_id)] in a private {!Placement_handle_store}.

    {b Order identity at venue.} Finam in turn addresses
    individual orders by its own server-assigned id, while
    [Rest.t] still speaks [client_order_id]. A second internal
    [client_order_id ↦ order_id] cache keeps the venue-side
    translation hot; cache misses fall back to scanning [GET
    /orders] so the mapping survives adapter restarts as long as
    Finam still holds the order. *)

open Core

type t = {
  rest : Rest.t;
  account_id : string;
  placements : Placement_handle_store.t;
  order_id_by_cid : (string, string) Hashtbl.t;
  mutex : Eio.Mutex.t;
}

let name = "finam"

let make ~account_id (rest : Rest.t) : t =
  {
    rest;
    account_id;
    placements = Placement_handle_store.create ();
    order_id_by_cid = Hashtbl.create 16;
    mutex = Eio.Mutex.create ();
  }

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

let remember t ~client_order_id ~order_id =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.replace t.order_id_by_cid client_order_id order_id)

let resolve_order_id t ~client_order_id =
  let cached =
    Eio.Mutex.use_ro t.mutex (fun () -> Hashtbl.find_opt t.order_id_by_cid client_order_id)
  in
  match cached with
  | Some id -> id
  | None -> (
      let orders = Rest.get_orders t.rest ~account_id:t.account_id in
      match
        List.find_opt
          (fun (o : External_order.t) -> o.client_order_id = client_order_id)
          orders
      with
      | Some o ->
          remember t ~client_order_id ~order_id:o.order_id;
          o.order_id
      | None ->
          failwith
            (Printf.sprintf "finam: no order with client_order_id=%s" client_order_id))

(** UUID v4 with dashes stripped. Finam's REST validator returns
    400 on dashes ("letters, numbers and space" only), and 32 hex
    digits comfortably satisfy that rule while retaining full UUIDv4
    collision resistance. *)
let mint_client_order_id () =
  let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
  String.concat "" (String.split_on_char '-' uuid)

let project ~placement_id (v : External_order.t) : Order_view_model.t =
  Order_view_model.of_domain (External_order.to_broker_domain ~placement_id v)

let place_order t ~placement_id ~instrument ~side ~quantity ~kind ~tif :
    Order_view_model.t =
  let cid = mint_client_order_id () in
  (match
     Placement_handle_store.record t.placements ~placement_id ~client_order_id:cid
   with
  | `Ok | `Already_exists -> ());
  let external_order =
    Rest.place_order t.rest ~account_id:t.account_id ~instrument ~side ~quantity ~kind
      ~tif ~client_order_id:cid ()
  in
  remember t ~client_order_id:cid ~order_id:external_order.order_id;
  project ~placement_id external_order

let cancel_order t ~placement_id : Order_view_model.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      let external_order =
        Rest.cancel_order t.rest ~account_id:t.account_id ~order_id:order_id
      in
      Some (project ~placement_id external_order)

let get_order t ~placement_id : Order_view_model.t option =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> None
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      let external_order =
        Rest.get_order t.rest ~account_id:t.account_id ~order_id:order_id
      in
      Some (project ~placement_id external_order)

let get_executions t ~placement_id : Execution_view_model.t list =
  match Placement_handle_store.find_client_order_id t.placements ~placement_id with
  | None -> []
  | Some cid ->
      let order_id = resolve_order_id t ~client_order_id:cid in
      Rest.get_trades t.rest ~account_id:t.account_id
      |> List.filter_map (fun (at : Dto.account_trade) ->
          if at.order_id = order_id then
            Some (Execution_view_model.of_domain at.execution)
          else None)

let as_broker (t : t) : Broker.client =
  Broker.make
    (module struct
      type nonrec t = t

      let name = name
      let bars = bars
      let venues = venues
      let place_order = place_order
      let cancel_order = cancel_order
      let get_order = get_order
      let get_executions = get_executions
    end)
    t
