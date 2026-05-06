module type S = sig
  type 'state t

  val put : 'state t -> correlation_id:string -> 'state -> [ `Ok | `Already_exists ]

  val get : 'state t -> correlation_id:string -> 'state option

  val update :
    'state t ->
    correlation_id:string ->
    f:('state -> [ `Replace of 'state | `Delete ]) ->
    [ `Updated | `Not_found ]

  val length : 'state t -> int
end
