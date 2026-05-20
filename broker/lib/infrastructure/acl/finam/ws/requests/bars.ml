let envelope ~action ~token ~instrument ~timeframe : Yojson.Safe.t =
  `Assoc
    [
      ("action", `String action);
      ("type", `String "BARS");
      ( "data",
        `Assoc
          [
            ("symbol", `String (Routing.qualify_instrument instrument));
            ("timeframe", `String (Rest.timeframe_wire timeframe));
          ] );
      ("token", `String token);
    ]

let subscribe = envelope ~action:"SUBSCRIBE"
let unsubscribe = envelope ~action:"UNSUBSCRIBE"
