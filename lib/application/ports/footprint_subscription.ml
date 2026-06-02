type t = {
  watch : symbol:string -> boundary:string -> unit;
  unwatch : symbol:string -> boundary:string -> unit;
}

let noop : t =
  {
    watch = (fun ~symbol:_ ~boundary:_ -> ());
    unwatch = (fun ~symbol:_ ~boundary:_ -> ());
  }
