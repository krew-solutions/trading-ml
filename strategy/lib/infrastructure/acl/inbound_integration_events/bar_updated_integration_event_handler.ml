open Core

module Bar_updated = Bar_updated_integration_event

module Make (Bus : Bus.Event_bus.S) = struct
  type t = { stream : Candle.t Eio.Stream.t }

  let make ~capacity = { stream = Eio.Stream.create capacity }

  let source t = Eio_stream.of_eio_stream t.stream

  let matches_instrument
      (filter : Instrument.t)
      (vm : Strategy_inbound_queries.Instrument_view_model.t) : bool =
    String.equal vm.ticker (Ticker.to_string (Instrument.ticker filter))
    && String.equal vm.venue (Mic.to_string (Instrument.venue filter))
    && Option.equal String.equal vm.isin
         (Option.map Isin.to_string (Instrument.isin filter))
    && Option.equal String.equal vm.board
         (Option.map Board.to_string (Instrument.board filter))

  let candle_of_dto (vm : Strategy_inbound_queries.Candle_view_model.t) : Candle.t =
    Candle.make ~ts:vm.ts ~open_:(Decimal.of_string vm.open_)
      ~high:(Decimal.of_string vm.high) ~low:(Decimal.of_string vm.low)
      ~close:(Decimal.of_string vm.close) ~volume:(Decimal.of_string vm.volume)

  let attach (t : t) ~(events : Bar_updated.t Bus.t) ~(instrument : Instrument.t) :
      Bus.subscription =
    Bus.subscribe events (fun (ev : Bar_updated.t) ->
        if matches_instrument instrument ev.instrument then
          Eio.Stream.add t.stream (candle_of_dto ev.bar))
end
