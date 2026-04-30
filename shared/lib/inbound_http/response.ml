let json ?(status = `OK) (j : Yojson.Safe.t) =
  let body = Cohttp_eio.Body.of_string (Yojson.Safe.to_string j) in
  let headers =
    Cohttp.Header.of_list
      [
        ("Content-Type", "application/json");
        ("Access-Control-Allow-Origin", "*");
        ("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        ("Access-Control-Allow-Headers", "Content-Type");
      ]
  in
  Cohttp_eio.Server.respond ~status ~headers ~body ()

let text ?(status = `OK) s =
  let body = Cohttp_eio.Body.of_string s in
  let headers =
    Cohttp.Header.of_list
      [ ("Content-Type", "text/plain"); ("Access-Control-Allow-Origin", "*") ]
  in
  Cohttp_eio.Server.respond ~status ~headers ~body ()
