type t =
  | Immediate of Immediate.state
  | Twap of Twap.state
  | Vwap of Vwap.state
  | Pov of Pov.state
  | Iceberg of Iceberg.state
  | Implementation_shortfall of Implementation_shortfall.state

let init
    ~(intent : Values.Trade_intent.t)
    ~(directive : Values.Execution_directive.t)
    ~now =
  match directive with
  | Values.Execution_directive.Immediate ->
      let state, decision = Immediate.init ~intent ~now in
      (Immediate state, decision)
  | Values.Execution_directive.Twap params ->
      let state, decision = Twap.init ~intent ~params ~now in
      (Twap state, decision)
  | Values.Execution_directive.Vwap params ->
      let state, decision = Vwap.init ~intent ~params ~now in
      (Vwap state, decision)
  | Values.Execution_directive.Pov params ->
      let state, decision = Pov.init ~intent ~params ~now in
      (Pov state, decision)
  | Values.Execution_directive.Iceberg params ->
      let state, decision = Iceberg.init ~intent ~params ~now in
      (Iceberg state, decision)
  | Values.Execution_directive.Implementation_shortfall params ->
      let state, decision = Implementation_shortfall.init ~intent ~params ~now in
      (Implementation_shortfall state, decision)

let on_event (t : t) (input : Input.t) ~now : t * Decision.t =
  match t with
  | Immediate state ->
      let state', decision = Immediate.on_event state input ~now in
      (Immediate state', decision)
  | Twap state ->
      let state', decision = Twap.on_event state input ~now in
      (Twap state', decision)
  | Vwap state ->
      let state', decision = Vwap.on_event state input ~now in
      (Vwap state', decision)
  | Pov state ->
      let state', decision = Pov.on_event state input ~now in
      (Pov state', decision)
  | Iceberg state ->
      let state', decision = Iceberg.on_event state input ~now in
      (Iceberg state', decision)
  | Implementation_shortfall state ->
      let state', decision = Implementation_shortfall.on_event state input ~now in
      (Implementation_shortfall state', decision)

let is_complete = function
  | Immediate state -> Immediate.is_complete state
  | Twap state -> Twap.is_complete state
  | Vwap state -> Vwap.is_complete state
  | Pov state -> Pov.is_complete state
  | Iceberg state -> Iceberg.is_complete state
  | Implementation_shortfall state -> Implementation_shortfall.is_complete state
