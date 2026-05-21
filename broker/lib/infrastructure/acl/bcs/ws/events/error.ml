type t = { code : string; message : string }

let parse (j : Yojson.Safe.t) : t option =
  let open Yojson.Safe.Util in
  match member "errors" j with
  | `List (e :: _) ->
      let code =
        match member "code" e with
        | `String s -> s
        | _ -> ""
      in
      let message =
        match member "message" e with
        | `String s -> s
        | _ -> ""
      in
      Some { code; message }
  | _ -> None
