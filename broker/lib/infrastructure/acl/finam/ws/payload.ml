let unwrap (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `String s -> ( try Yojson.Safe.from_string s with _ -> `Null)
  | other -> other
