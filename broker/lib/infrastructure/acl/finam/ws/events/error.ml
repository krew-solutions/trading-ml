type t = { code : int; type_ : string; message : string }

let parse (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let info = member "error_info" j in
  {
    code =
      (match member "code" info with
      | `Int n -> n
      | _ -> 0);
    type_ =
      (match member "type" info with
      | `String s -> s
      | _ -> "");
    message =
      (match member "message" info with
      | `String s -> s
      | _ -> "");
  }
