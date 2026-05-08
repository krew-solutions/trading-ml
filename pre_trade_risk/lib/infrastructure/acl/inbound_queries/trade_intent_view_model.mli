(** Inbound DTO mirror of a trade-intent view model. Mirrors the wire
    shape published by
    {!Portfolio_management_integration_events.Trade_intents_planned_integration_event}'s
    leg, kept independent so PM can evolve its outbound schema without
    forcing this BC's deserializer to move in lockstep. *)

type t = {
  book_id : string;
  instrument : Instrument_view_model.t;
  side : string;
  quantity : string;
}
[@@deriving yojson]
