let () =
  Alcotest.run "trading" [
    "decimal",   Test_decimal.tests;
    "portfolio", Test_portfolio.tests;
    "backtest",  Test_backtest.tests;
    "finam dto", Test_finam_dto.tests;
    "finam auth", Test_auth.tests;
    "finam ws frame", Test_ws_frame.tests;
    "finam ws client", Test_ws_client.tests;
    (* Indicators — one file per indicator under test/indicators/. *)
    "sma",       Sma_test.tests;
    "ema",       Ema_test.tests;
    "wma",       Wma_test.tests;
    "rsi",       Rsi_test.tests;
    "macd",      Macd_test.tests;
    "macd-w",    Macd_weighted_test.tests;
    "bollinger", Bollinger_test.tests;
    "atr",       Atr_test.tests;
    "obv",       Obv_test.tests;
    "a/d",       Ad_test.tests;
    "chaikin osc", Chaikin_oscillator_test.tests;
    "stochastic", Stochastic_test.tests;
    "mfi",       Mfi_test.tests;
    "cmf",       Cmf_test.tests;
    "cvi",       Cvi_test.tests;
    "cvd",       Cvd_test.tests;
    "volume",    Volume_test.tests;
    "volume ma", Volume_ma_test.tests;
  ]
