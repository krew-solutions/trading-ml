open Core

let envelope ~action ~token (instrument : Instrument.t) : Yojson.Safe.t =
  `Assoc
    [
      ("action", `String action);
      ("type", `String "INSTRUMENT_TRADES");
      ("data", `Assoc [ ("symbol", `String (Routing.qualify_instrument instrument)) ]);
      ("token", `String token);
    ]

let subscribe = envelope ~action:"SUBSCRIBE"
let unsubscribe = envelope ~action:"UNSUBSCRIBE"
