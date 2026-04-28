type ('a, 'err) t = ('a, 'err list) result

let succeed x = Ok x
let fail e = Error [ e ]

let map f = function
  | Ok x -> Ok (f x)
  | Error e -> Error e

let apply rf rx =
  match (rf, rx) with
  | Ok f, Ok x -> Ok (f x)
  | Error e, Ok _ | Ok _, Error e -> Error e
  | Error e1, Error e2 -> Error (e1 @ e2)

let bind r f =
  match r with
  | Ok x -> f x
  | Error e -> Error e

let both ra rb =
  match (ra, rb) with
  | Ok a, Ok b -> Ok (a, b)
  | Error e, Ok _ | Ok _, Error e -> Error e
  | Error e1, Error e2 -> Error (e1 @ e2)

let of_result = function
  | Ok x -> Ok x
  | Error e -> Error [ e ]

let ( <!> ) = map
let ( <*> ) = apply

let ( let+ ) r f = map f r
let ( and+ ) = both

let ( let* ) r f = bind r f
