type t = { event : string; code : int; reason : string }

let parse (j : Yojson.Safe.t) : t =
  let open Yojson.Safe.Util in
  let info = member "event_info" j in
  {
    event =
      (match member "event" info with
      | `String s -> s
      | _ -> "");
    code =
      (match member "code" info with
      | `Int n -> n
      | _ -> 0);
    reason =
      (match member "reason" info with
      | `String s -> s
      | _ -> "");
  }
