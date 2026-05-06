type subscription = { cancel : unit -> unit }

type 'a consumer = { subscribe : ('a -> unit) -> subscription }

type 'a producer = { publish : 'a -> unit }

module type Adapter = sig
  type 'a adapter_consumer
  type 'a adapter_producer
  type adapter_subscription

  val consumer :
    uri:string -> group:string -> deserialize:(string -> 'a) -> 'a adapter_consumer

  val producer : uri:string -> serialize:('a -> string) -> 'a adapter_producer

  val publish : 'a adapter_producer -> 'a -> unit

  val subscribe : 'a adapter_consumer -> ('a -> unit) -> adapter_subscription

  val unsubscribe : adapter_subscription -> unit
end

type bus = { adapters : (string, (module Adapter)) Hashtbl.t }

exception Already_registered of string

exception Unknown_scheme of string

let create () = { adapters = Hashtbl.create 4 }

let register bus ~scheme adapter =
  if Hashtbl.mem bus.adapters scheme then raise (Already_registered scheme);
  Hashtbl.replace bus.adapters scheme adapter

let scheme_of_uri uri =
  match String.index_opt uri ':' with
  | Some i -> String.sub uri 0 i
  | None -> raise (Unknown_scheme uri)

let consumer (type a) bus ~uri ~group ~(deserialize : string -> a) : a consumer =
  let scheme = scheme_of_uri uri in
  match Hashtbl.find_opt bus.adapters scheme with
  | None -> raise (Unknown_scheme scheme)
  | Some (module A : Adapter) ->
      let raw = A.consumer ~uri ~group ~deserialize in
      {
        subscribe =
          (fun cb ->
            let raw_sub = A.subscribe raw cb in
            { cancel = (fun () -> A.unsubscribe raw_sub) });
      }

let producer (type a) bus ~uri ~(serialize : a -> string) : a producer =
  let scheme = scheme_of_uri uri in
  match Hashtbl.find_opt bus.adapters scheme with
  | None -> raise (Unknown_scheme scheme)
  | Some (module A : Adapter) ->
      let raw = A.producer ~uri ~serialize in
      { publish = (fun v -> A.publish raw v) }

let publish p v = p.publish v

let subscribe c cb = c.subscribe cb

let unsubscribe s = s.cancel ()
