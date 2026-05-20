open Core

let envelope ~action ~token (instruments : Instrument.t list) : Yojson.Safe.t =
  `Assoc
    [
      ("action", `String action);
      ("type", `String "QUOTES");
      ( "data",
        `Assoc
          [
            ( "symbols",
              `List
                (List.map (fun i -> `String (Routing.qualify_instrument i)) instruments)
            );
          ] );
      ("token", `String token);
    ]

let subscribe = envelope ~action:"SUBSCRIBE"
let unsubscribe = envelope ~action:"UNSUBSCRIBE"
