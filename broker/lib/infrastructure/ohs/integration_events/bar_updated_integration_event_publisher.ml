let make ~bus =
  Bus.publish
    (Bus.producer bus ~uri:"in-memory://broker.bar-updated" ~serialize:(fun v ->
         Yojson.Safe.to_string
           (Broker_integration_events.Bar_updated_integration_event.yojson_of_t v)))
