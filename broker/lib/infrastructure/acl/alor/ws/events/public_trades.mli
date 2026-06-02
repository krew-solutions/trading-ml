(** Inbound Alor public-tape ([AllTradesGetAndSubscribe]) frame parser.

    One executed tape print -> {!Public_trade_printed}, the
    venue's all-participants flow (distinct from the personal
    [TradesGetAndSubscribeV2] fills). [~instrument] is the subscribed
    instrument, stamped onto the event as-is — the "Simple" frame omits
    [exchange], so it cannot be reconstructed from the body. [side] is the
    aggressor ("buy"/"sell", else [None]). *)

type t = Broker_domain.Remote_broker.Events.Public_trade_printed.t

val parse : instrument:Core.Instrument.t -> Yojson.Safe.t -> t
