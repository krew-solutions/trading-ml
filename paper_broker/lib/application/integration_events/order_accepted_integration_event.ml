include Order_accepted_integration_event_t
include Order_accepted_integration_event_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Paper_broker.Order.Events.Order_accepted.t

let of_domain ~(correlation_id : string) (ev : domain) : t =
  {
    correlation_id;
    placement_id = Paper_broker.Order.Values.Placement_id.to_int ev.placement_id;
  }
