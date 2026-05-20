open Core

let bump_total (total_filled : (int, Decimal.t) Hashtbl.t) ~placement_id ~delta :
    Decimal.t =
  let prev =
    match Hashtbl.find_opt total_filled placement_id with
    | Some d -> d
    | None -> Decimal.zero
  in
  let next = Decimal.add prev delta in
  Hashtbl.replace total_filled placement_id next;
  next

let handle_one
    ~(finam : Finam_broker.t)
    ~(origin_correlation_id : placement_id:int -> string option)
    ~(total_filled : (int, Decimal.t) Hashtbl.t)
    ~(publish_order_filled :
       Broker_integration_events.Order_filled_integration_event.t -> unit)
    (tu : Trade.update) : unit =
  match Finam_broker.placement_id_by_order_id finam ~order_id:tu.order_id with
  | None -> Log.warn "[finam ws] trade for unknown order_id=%s — skipping" tu.order_id
  | Some placement_id -> (
      match origin_correlation_id ~placement_id with
      | None ->
          Log.warn
            "[finam ws] trade for placement_id=%d has no Submit correlation_id; skipping"
            placement_id
      | Some correlation_id ->
          let new_total = bump_total total_filled ~placement_id ~delta:tu.quantity in
          let ie : Broker_integration_events.Order_filled_integration_event.t =
            {
              correlation_id;
              placement_id;
              id = tu.order_id;
              exec_id = tu.trade_id;
              instrument =
                Broker_view_models.Instrument_view_model.of_domain tu.instrument;
              side = Side.to_string tu.side;
              fill_quantity = Decimal.to_string tu.quantity;
              fill_price = Decimal.to_string tu.price;
              fee = "0";
              new_total_filled = Decimal.to_string new_total;
              fill_ts = Datetime.Iso8601.format tu.ts;
            }
          in
          publish_order_filled ie)

let handle
    ~finam
    ~origin_correlation_id
    ~total_filled
    ~publish_order_filled
    (trades : Trade.update list) : unit =
  List.iter
    (handle_one ~finam ~origin_correlation_id ~total_filled ~publish_order_filled)
    trades
