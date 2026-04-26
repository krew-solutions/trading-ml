open Core

type fill = {
  client_order_id : string;
  ts : int64;
  instrument : Instrument.t;
  side : Side.t;
  quantity : Decimal.t;
  price : Decimal.t;
  fee : Decimal.t;
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
  mutable portfolio : Engine.Portfolio.t;
  last_ts : (Instrument.t, int64) Hashtbl.t;
  mutex : Mutex.t;
  fee_rate : float;
  slippage_bps : float;
  participation_rate : float option;
  mutable fill_listeners : (fill -> unit) list;
}

let make
    ?(initial_cash = Decimal.of_int 1_000_000)
    ?(fee_rate = 0.0)
    ?(slippage_bps = 0.0)
    ?participation_rate
    ~source
    () =
  {
    source;
    book = [];
    fills = [];
    portfolio = Engine.Portfolio.empty ~cash:initial_cash;
    last_ts = Hashtbl.create 8;
    mutex = Mutex.create ();
    fee_rate;
    slippage_bps;
    participation_rate;
    fill_listeners = [];
  }

(** Paper's critical sections are non-blocking (no IO, no effects) so
    {!Stdlib.Mutex} is sufficient — we don't need Eio's cancellation
    machinery to guard short mutations of the in-memory book. This
    also lets unit tests drive the decorator without an Eio runtime. *)
let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let on_fill t cb = with_lock t (fun () -> t.fill_listeners <- cb :: t.fill_listeners)

let name = "paper"

let last_ts_for t instrument =
  Hashtbl.find_opt t.last_ts instrument |> Option.value ~default:0L

let new_order ~instrument ~side ~quantity ~kind ~tif ~client_order_id : Order.t =
  {
    id = client_order_id;
    exec_id = "";
    instrument;
    side;
    quantity;
    filled = Decimal.zero;
    remaining = quantity;
    kind;
    tif;
    status = Order.New;
    created_ts = Int64.of_float (Unix.gettimeofday ());
    client_order_id;
  }

(** Decide whether bar [c] triggers a fill for [e] and return the
    canonical price. Market: [open_]. Limit: conservative — [open_]
    when the bar gaps past the limit, else the limit itself. Stops
    mirror limits but with inverse polarity. Stop-limit is not
    simulated in this cut (stays [New]). *)
let price_if_filled (e : entry) (c : Candle.t) : Decimal.t option =
  let open_ = c.Candle.open_ in
  let low = c.low in
  let high = c.high in
  match (e.order.kind, e.order.side) with
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

(** Slippage applies only to orders that pay for immediacy: {!Market}
    eats the spread, {!Stop} triggers and is filled at whatever's
    there. {!Limit} and {!Stop_limit} have a price ceiling/floor that
    the trader selected — no slippage beyond the stated price. *)
let is_slippable (k : Order.kind) =
  match k with
  | Market | Stop _ -> true
  | Limit _ | Stop_limit _ -> false

let apply_slippage ~bps (side : Side.t) (price : Decimal.t) : Decimal.t =
  if bps = 0.0 then price
  else
    let factor =
      match side with
      | Buy -> 1.0 +. (bps /. 10_000.0)
      | Sell -> 1.0 -. (bps /. 10_000.0)
    in
    Decimal.mul price (Decimal.of_float factor)

(** How much of [remaining] can fill against bar [c], given the
    configured participation cap. With [None] (default), no cap. *)
let fillable_qty t (remaining : Decimal.t) (c : Candle.t) : Decimal.t =
  match t.participation_rate with
  | None -> remaining
  | Some rate ->
      let cap = Decimal.mul c.volume (Decimal.of_float rate) in
      Decimal.min remaining cap

let apply_fill t (e : entry) (c : Candle.t) (price_intent : Decimal.t) =
  let o = e.order in
  let qty = fillable_qty t o.remaining c in
  if Decimal.is_zero qty then () (* volume too thin; try again next bar *)
  else
    let price =
      if is_slippable o.kind then apply_slippage ~bps:t.slippage_bps o.side price_intent
      else price_intent
    in
    let fee =
      if t.fee_rate = 0.0 then Decimal.zero
      else Decimal.mul (Decimal.mul qty price) (Decimal.of_float t.fee_rate)
    in
    let new_filled = Decimal.add o.filled qty in
    let new_remaining = Decimal.sub o.remaining qty in
    let new_status =
      if Decimal.is_zero new_remaining then Order.Filled else Order.Partially_filled
    in
    e.order <-
      {
        o with
        status = new_status;
        filled = new_filled;
        remaining = new_remaining;
        exec_id = o.client_order_id ^ "-" ^ Int64.to_string c.ts;
      };
    let fill_rec =
      {
        client_order_id = o.client_order_id;
        ts = c.ts;
        instrument = o.instrument;
        side = o.side;
        quantity = qty;
        price;
        fee;
      }
    in
    t.fills <- fill_rec :: t.fills;
    t.portfolio <-
      Engine.Portfolio.fill t.portfolio ~instrument:o.instrument ~side:o.side
        ~quantity:qty ~price ~fee;
    (* Fire synchronous listeners (e.g., Live_engine's commit_fill
       handler). Call them in registration order — reverse the stack
       since listeners are prepended. Listeners run inside the mutex
       for state consistency; they must not re-enter Paper APIs. *)
    List.iter (fun cb -> cb fill_rec) (List.rev t.fill_listeners)

let on_bar t ~instrument (c : Candle.t) =
  with_lock t (fun () ->
      let prev = last_ts_for t instrument in
      if Int64.compare c.ts prev > 0 then Hashtbl.replace t.last_ts instrument c.ts;
      List.iter
        (fun (_, e) ->
          if
            (not (Order.is_done e.order))
            && Instrument.equal e.order.instrument instrument
            && Int64.compare c.ts e.placed_after_ts > 0
          then
            match price_if_filled e c with
            | Some price -> apply_fill t e c price
            | None -> ())
        t.book)

let place_order t ~instrument ~side ~quantity ~kind ~tif ~client_order_id =
  with_lock t (fun () ->
      let o = new_order ~instrument ~side ~quantity ~kind ~tif ~client_order_id in
      let entry = { order = o; placed_after_ts = last_ts_for t instrument } in
      t.book <- (client_order_id, entry) :: t.book;
      o)

let get_orders t = with_lock t (fun () -> List.rev_map (fun (_, e) -> e.order) t.book)

let get_order t ~client_order_id =
  with_lock t (fun () ->
      match List.assoc_opt client_order_id t.book with
      | Some e -> e.order
      | None ->
          failwith
            (Printf.sprintf "paper: no order with client_order_id=%s" client_order_id))

let cancel_order t ~client_order_id =
  with_lock t (fun () ->
      match List.assoc_opt client_order_id t.book with
      | None ->
          failwith
            (Printf.sprintf "paper: no order with client_order_id=%s" client_order_id)
      | Some e ->
          if not (Order.is_done e.order) then
            e.order <- { e.order with status = Order.Cancelled };
          e.order)

let fills t = with_lock t (fun () -> List.rev t.fills)

(** Project {!fill}s matching [client_order_id] into domain
    {!Order.execution} records, chronologically. Paper's fill
    list IS the execution history — one entry per simulated
    partial fill — so the projection is a trivial filter. *)
let get_executions t ~client_order_id =
  with_lock t (fun () ->
      List.filter_map
        (fun (f : fill) ->
          if f.client_order_id = client_order_id then
            Some
              ({ ts = f.ts; quantity = f.quantity; price = f.price; fee = f.fee }
                : Order.execution)
          else None)
        (List.rev t.fills))

let portfolio t = with_lock t (fun () -> t.portfolio)

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

(** Paper is a decorator — delegate to [source] so the cid format
    matches whatever the wrapped live broker expects. That keeps
    backtests routed through Paper→BCS emitting dashed UUIDs and
    Paper→Finam emitting 32-hex, even though Paper itself doesn't
    care what the cid looks like. *)
let generate_client_order_id t = Broker.generate_client_order_id t.source

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
