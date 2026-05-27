module Cluster = Footprint.Values.Cluster
include Cluster_view_model_t
include Cluster_view_model_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Cluster.t

let of_domain (c : domain) : t =
  {
    price = Decimal.to_string c.Cluster.price;
    buy_volume = Decimal.to_string c.Cluster.buy_volume;
    sell_volume = Decimal.to_string c.Cluster.sell_volume;
    indeterminate_volume = Decimal.to_string c.Cluster.indeterminate_volume;
  }
