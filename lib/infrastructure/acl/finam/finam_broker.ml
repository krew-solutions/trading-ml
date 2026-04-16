(** Adapter: exposes [Finam.Rest.t] through the broker-agnostic
    [Broker.S] interface. All Finam-specific translation lives here so
    callers (server, CLI, tests) program against [Broker.client]. *)

type t = Rest.t

let name = "finam"

let bars t ~n ~symbol ~timeframe =
  Rest.bars t ~n ~symbol ~timeframe

let exchanges t : Broker.exchange list =
  let j = Rest.exchanges t in
  match Yojson.Safe.Util.member "exchanges" j with
  | `List items ->
    List.filter_map (fun item ->
      let open Yojson.Safe.Util in
      match member "mic" item, member "name" item with
      | `String m, `String n -> Some { Broker.mic = m; name = n }
      | `String m, _ -> Some { Broker.mic = m; name = m }
      | _ -> None
    ) items
  | _ -> []

let as_broker (rest : Rest.t) : Broker.client =
  Broker.make (module struct
    type nonrec t = t
    let name = name
    let bars = bars
    let exchanges = exchanges
  end) rest
