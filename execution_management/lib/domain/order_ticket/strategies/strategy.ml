type t = Immediate of Immediate.state

let init ~(intent : Values.Trade_intent.t)
    ~(directive : Values.Execution_directive.t) ~now =
  match directive with
  | Values.Execution_directive.Immediate ->
      let state, decision = Immediate.init ~intent ~now in
      (Immediate state, decision)

let on_event (t : t) (input : Input.t) ~now : t * Decision.t =
  match t with
  | Immediate state ->
      let state', decision = Immediate.on_event state input ~now in
      (Immediate state', decision)

let is_complete = function Immediate state -> Immediate.is_complete state
