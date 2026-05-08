open Core

type config = {
  strategy : Strategies.Strategy.t;
  instrument : Instrument.t;
  strategy_id : string;
}

module Signal_detected = Strategy_integration_events.Signal_detected_integration_event

type t = {
  mutable strat : Strategies.Strategy.t;
  cfg : config;
  publish_signal_detected : Signal_detected.t -> unit;
  mutable last_bar_ts : int64;
  mu : Mutex.t;
}

let make ~(config : config) ~publish_signal_detected =
  {
    strat = config.strategy;
    cfg = config;
    publish_signal_detected;
    last_bar_ts = Int64.min_int;
    mu = Mutex.create ();
  }

let with_lock t f =
  Mutex.lock t.mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mu) f

let on_bar t (c : Candle.t) =
  with_lock t (fun () ->
      if Int64.compare c.ts t.last_bar_ts <= 0 then ()
      else begin
        t.last_bar_ts <- c.ts;
        let strat', sig_ = Strategies.Strategy.on_candle t.strat t.cfg.instrument c in
        t.strat <- strat';
        match sig_.action with
        | Hold -> ()
        | _ ->
            let ie =
              Signal_detected.of_domain ~strategy_id:t.cfg.strategy_id
                ~price:c.Candle.close sig_
            in
            t.publish_signal_detected ie
      end)

let run t ~source = Stream.iter (on_bar t) source
