(** Unit test runner. [test/unit/] mirrors [lib/] by directory; dune's
    [include_subdirs unqualified] flattens everything into a single
    module namespace, so filenames are globally unique — vendor-specific
    tests carry a broker prefix to avoid collisions between e.g.
    [finam/auth_test.ml] and [bcs/auth_test.ml]. *)

let () =
  Alcotest.run "trading-unit" [
    (* Domain *)
    "stream",      Stream_test.tests;
    "eio_stream",  Eio_stream_test.tests;
    "decimal",     Decimal_test.tests;
    "mic",         Mic_test.tests;
    "ticker",      Ticker_test.tests;
    "isin",        Isin_test.tests;
    "board",       Board_test.tests;
    "instrument",  Instrument_test.tests;
    "portfolio",   Portfolio_test.tests;
    "backtest",    Backtest_test.tests;
    (* Indicators — one file per indicator, mirrored from lib *)
    "sma",         Sma_test.tests;
    "ema",         Ema_test.tests;
    "wma",         Wma_test.tests;
    "rsi",         Rsi_test.tests;
    "macd",        Macd_test.tests;
    "macd-w",      Macd_weighted_test.tests;
    "bollinger",   Bollinger_test.tests;
    "atr",         Atr_test.tests;
    "obv",         Obv_test.tests;
    "a/d",         Ad_test.tests;
    "chaikin osc", Chaikin_oscillator_test.tests;
    "stochastic",  Stochastic_test.tests;
    "mfi",         Mfi_test.tests;
    "cmf",         Cmf_test.tests;
    "cvi",         Cvi_test.tests;
    "cvd",         Cvd_test.tests;
    "volume",      Volume_test.tests;
    "volume ma",   Volume_ma_test.tests;
    (* Strategies *)
    "sma crossover",    Sma_crossover_test.tests;
    "rsi mean rev",     Rsi_mean_reversion_test.tests;
    "macd momentum",    Macd_momentum_test.tests;
    "bollinger brk",    Bollinger_breakout_test.tests;
    "mfi mean rev",     Mfi_mean_reversion_test.tests;
    "obv ma crossover", Obv_ma_crossover_test.tests;
    "chaikin momentum", Chaikin_momentum_test.tests;
    "ad ma crossover",  Ad_ma_crossover_test.tests;
    "strat registry",   Registry_test.tests;
    "composite strat",  Composite_test.tests;
    "gbt strategy",     Gbt_strategy_test.tests;
    (* ML *)
    "logistic",        Logistic_test.tests;
    "features",        Features_test.tests;
    "trainer",         Trainer_test.tests;
    "learned policy",  Learned_policy_test.tests;
    "gbt model",       Gbt_model_test.tests;
    "triple barrier",  Triple_barrier_test.tests;
    (* ACL: Finam *)
    "finam dto",       Finam_dto_test.tests;
    "finam auth",      Finam_auth_test.tests;
    "ws frame",        Websocket_frame_test.tests;
    "finam ws proto",  Finam_ws_test.tests;
    "finam orders",    Finam_order_test.tests;
    (* ACL: BCS *)
    "bcs auth",    Bcs_auth_test.tests;
    "bcs rest",    Bcs_rest_test.tests;
    "bcs ws",      Bcs_ws_test.tests;
    "bcs orders",  Bcs_order_test.tests;
    "bcs deals",   Bcs_deals_test.tests;
    (* Infrastructure: secret storage *)
    "token store", Token_store_test.tests;
    (* Infrastructure: Paper decorator *)
    "paper broker", Paper_broker_test.tests;
    (* Application: live engine *)
    "live engine",  Live_engine_test.tests;
    "bt vs live",   Differential_test.tests;
  ]
