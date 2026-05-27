open Core
include Trade_printed_integration_event_t
include Trade_printed_integration_event_j

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)

type domain = Broker_domain.Remote_broker.Events.Remote_public_trade_updated.t

(* The single side-mapping point (ADR 0032): the venue's reported
   aggressor, normalised to the wire tokens. [None] (Finam's
   SIDE_UNSPECIFIED — auction / negotiated, no initiator) becomes
   UNSPECIFIED. Flip Buy/Sell here if the venue's side ever proves to
   mark the resting order rather than the aggressor. *)
let aggressor_to_string = function
  | Some Side.Buy -> "BUY"
  | Some Side.Sell -> "SELL"
  | None -> "UNSPECIFIED"

let of_domain (ev : domain) : t =
  {
    symbol = Instrument.to_qualified ev.instrument;
    price = Decimal.to_string ev.price;
    size = Decimal.to_string ev.quantity;
    ts = Datetime.Iso8601.format ev.ts;
    aggressor = aggressor_to_string ev.side;
  }
