let envelope ~action ~token instrument : Yojson.Safe.t =
  `Assoc
    [
      ("action", `String action);
      ("type", `String "ORDER_BOOK");
      ("data", `Assoc [ ("symbol", `String (Routing.qualify_instrument instrument)) ]);
      ("token", `String token);
    ]

let subscribe = envelope ~action:"SUBSCRIBE"
let unsubscribe = envelope ~action:"UNSUBSCRIBE"
