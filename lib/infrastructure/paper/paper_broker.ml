open Core

type fill = {
  client_order_id : string;
  ts : int64;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
}

type entry = {
  mutable order : Order.t;
  (** Floor timestamp for fill evaluation. An order placed after bar
      with ts=T may only fill at bars with ts strictly greater than T
      — this is the "next-bar execution" rule that keeps paper fills
      consistent with the backtester and free of lookahead. *)
  placed_after_ts : int64;
}

type t = {
  source : Broker.client;
  mutable book : (string * entry) list;
  mutable fills : fill list;
  last_ts : (Instrument.t, int64) Hashtbl.t;
  mutex : Mutex.t;
}

let make ~source () = {
  source;
  book = [];
  fills = [];
  last_ts = Hashtbl.create 8;
  mutex = Mutex.create ();
}

(** Paper's critical sections are non-blocking (no IO, no effects) so
    {!Stdlib.Mutex} is sufficient — we don't need Eio's cancellation
    machinery to guard short mutations of the in-memory book. This
    also lets unit tests drive the decorator without an Eio runtime. *)
let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let name = "paper"

let last_ts_for t instrument =
  Hashtbl.find_opt t.last_ts instrument |> Option.value ~default:0L

let new_order ~instrument ~side ~quantity ~kind ~tif ~client_order_id : Order.t =
  {
    id = client_order_id;
    exec_id = "";
    instrument; side; quantity;
    filled = Decimal.zero;
    remaining = quantity;
    kind; tif;
    status = Order.New;
    created_ts = Int64.of_float (Unix.gettimeofday ());
    client_order_id;
  }

(** Decide whether bar [c] fills [e]. Returns [Some price] if it does,
    [None] otherwise. Market: fill at [open_]. Limit: fill at the most
    conservative price that's still inside the bar's range — [open_]
    when the bar gaps past the limit, else the limit itself. Stops
    mirror limits but with inverse polarity. Stop-limit is left
    pending; a full implementation would need two-phase state and is
    out of scope for this first cut. *)
let price_if_filled (e : entry) (c : Candle.t) : Decimal.t option =
  let open_ = c.Candle.open_ in
  let low = c.low in
  let high = c.high in
  match e.order.kind, e.order.side with
  | Market, _ -> Some open_
  | Limit lim, Buy ->
    if Decimal.compare open_ lim <= 0 then Some open_
    else if Decimal.compare low lim <= 0 then Some lim
    else None
  | Limit lim, Sell ->
    if Decimal.compare open_ lim >= 0 then Some open_
    else if Decimal.compare high lim >= 0 then Some lim
    else None
  | Stop stop, Buy ->
    if Decimal.compare open_ stop >= 0 then Some open_
    else if Decimal.compare high stop >= 0 then Some stop
    else None
  | Stop stop, Sell ->
    if Decimal.compare open_ stop <= 0 then Some open_
    else if Decimal.compare low stop <= 0 then Some stop
    else None
  | Stop_limit _, _ -> None

let apply_fill t (e : entry) (c : Candle.t) (price : Decimal.t) =
  let o = e.order in
  e.order <- { o with
    status = Order.Filled;
    filled = o.quantity;
    remaining = Decimal.zero;
    exec_id = o.client_order_id ^ "-" ^ Int64.to_string c.ts;
  };
  t.fills <- {
    client_order_id = o.client_order_id;
    ts = c.ts;
    instrument = o.instrument;
    side = o.side;
    quantity = o.quantity;
    price;
  } :: t.fills

let on_bar t ~instrument (c : Candle.t) =
  with_lock t (fun () ->
    let prev = last_ts_for t instrument in
    if Int64.compare c.ts prev > 0 then
      Hashtbl.replace t.last_ts instrument c.ts;
    List.iter (fun (_, e) ->
      if not (Order.is_done e.order)
         && Instrument.equal e.order.instrument instrument
         && Int64.compare c.ts e.placed_after_ts > 0
      then match price_if_filled e c with
        | Some price -> apply_fill t e c price
        | None -> ()
    ) t.book)

let place_order t ~instrument ~side ~quantity ~kind ~tif ~client_order_id =
  with_lock t (fun () ->
    let o = new_order ~instrument ~side ~quantity ~kind ~tif ~client_order_id in
    let entry = { order = o; placed_after_ts = last_ts_for t instrument } in
    t.book <- (client_order_id, entry) :: t.book;
    o)

let get_orders t =
  with_lock t (fun () ->
    List.rev_map (fun (_, e) -> e.order) t.book)

let get_order t ~client_order_id =
  with_lock t (fun () ->
    match List.assoc_opt client_order_id t.book with
    | Some e -> e.order
    | None ->
      failwith
        (Printf.sprintf "paper: no order with client_order_id=%s"
           client_order_id))

let cancel_order t ~client_order_id =
  with_lock t (fun () ->
    match List.assoc_opt client_order_id t.book with
    | None ->
      failwith
        (Printf.sprintf "paper: no order with client_order_id=%s"
           client_order_id)
    | Some e ->
      if not (Order.is_done e.order) then
        e.order <- { e.order with status = Order.Cancelled };
      e.order)

let fills t =
  with_lock t (fun () -> List.rev t.fills)

(** Market data path. Delegates to the wrapped source, then sinks the
    trailing candle into {!on_bar} so that simple deployments (e.g.
    synthetic source, no WS) still advance simulation state as the UI
    polls [/api/candles]. Live deployments with a WS feed will
    additionally call {!on_bar} on every upstream push — dedupe is
    safe (ts-based monotonicity guard inside [on_bar]). *)
let bars t ~n ~instrument ~timeframe =
  let cs = Broker.bars t.source ~n ~instrument ~timeframe in
  (match List.rev cs with
   | last :: _ -> on_bar t ~instrument last
   | [] -> ());
  cs

let venues t = Broker.venues t.source

let as_broker (t : t) : Broker.client =
  Broker.make (module struct
    type nonrec t = t
    let name = name
    let bars = bars
    let venues = venues
    let place_order = place_order
    let get_orders = get_orders
    let get_order = get_order
    let cancel_order = cancel_order
  end) t
