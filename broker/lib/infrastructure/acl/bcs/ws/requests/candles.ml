let envelope ~subscribe_type ~class_code ~ticker ~timeframe : Yojson.Safe.t =
  `Assoc
    [
      ("subscribeType", `Int subscribe_type);
      ("dataType", `Int 1);
      ("timeFrame", `String (Rest.timeframe_wire timeframe));
      ( "instruments",
        `List
          [
            `Assoc
              [
                ("classCode", `String class_code); ("ticker", `String ticker);
              ];
          ] );
    ]

let subscribe = envelope ~subscribe_type:0
let unsubscribe = envelope ~subscribe_type:1
