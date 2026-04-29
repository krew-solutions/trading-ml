type ('a, 'err) t = ('a, 'err list) result

let succeed x = Ok x
let fail e = Error [ e ]

let either success_fn failure_fn = function
  | Ok x -> success_fn x
  | Error e -> failure_fn e

let map f = either (fun x -> succeed (f x)) (fun e -> Error e)

let apply rf rx =
  match (rf, rx) with
  | Ok f, Ok x -> Ok (f x)
  | Error e, Ok _ | Ok _, Error e -> Error e
  | Error e1, Error e2 -> Error (e1 @ e2)

let bind r f = either f (fun e -> Error e) r

let both ra rb =
  match (ra, rb) with
  | Ok a, Ok b -> Ok (a, b)
  | Error e, Ok _ | Ok _, Error e -> Error e
  | Error e1, Error e2 -> Error (e1 @ e2)

let of_result = function
  | Ok x -> Ok x
  | Error e -> Error [ e ]

let switch f x = succeed (f x)

let tee f x =
  f x;
  x

let try_catch f exn_handler x = try succeed (f x) with e -> fail (exn_handler e)

let double_map success_fn failure_fn =
  either (fun x -> succeed (success_fn x)) (fun e -> Error (List.map failure_fn e))

let plus add_success add_failure switch1 switch2 x =
  match (switch1 x, switch2 x) with
  | Ok s1, Ok s2 -> Ok (add_success s1 s2)
  | Error f1, Ok _ -> Error f1
  | Ok _, Error f2 -> Error f2
  | Error f1, Error f2 -> Error (add_failure f1 f2)

let ( <!> ) = map
let ( <*> ) = apply
let ( >>= ) = bind
let ( >=> ) f g x = bind (f x) g

let ( let+ ) r f = map f r
let ( and+ ) = both

let ( let* ) r f = bind r f
