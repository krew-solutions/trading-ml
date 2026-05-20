let envelope ~action ~token ~account_id : Yojson.Safe.t =
  `Assoc
    [
      ("action", `String action);
      ("type", `String "TRADES");
      ("data", `Assoc [ ("account_id", `String account_id) ]);
      ("token", `String token);
    ]

let subscribe = envelope ~action:"SUBSCRIBE"
let unsubscribe = envelope ~action:"UNSUBSCRIBE"
