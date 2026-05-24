module CR = Portfolio_management_commands.Configure_risk_command
module CRH = Portfolio_management_commands.Configure_risk_command_handler
module SBA = Portfolio_management_commands.Subscribe_book_to_alpha_command
module SBAH = Portfolio_management_commands.Subscribe_book_to_alpha_command_handler
module DPM = Portfolio_management_commands.Define_pair_mr_command
module DPMH = Portfolio_management_commands.Define_pair_mr_command_handler
module DPKM = Portfolio_management_commands.Define_pair_kalman_mr_command
module DPKMH = Portfolio_management_commands.Define_pair_kalman_mr_command_handler

let success_body : Yojson.Safe.t = `Assoc [ ("result", `String "ok") ]

let malformed_body ~msg : Yojson.Safe.t =
  `Assoc [ ("result", `String "malformed_request"); ("message", `String msg) ]

let validation_body_of_strings (errors : string list) : Yojson.Safe.t =
  `Assoc
    [
      ("result", `String "validation_failed");
      ("errors", `List (List.map (fun s -> `String s) errors));
    ]

let parse_body parse_string body : ('a, string) result =
  let body_str = Eio.Flow.read_all body in
  try Ok (parse_string body_str)
  with Atdgen_runtime.Oj_run.Error msg | Yojson.Json_error msg -> Error msg

let json_response ~status body : Inbound_http.Route.response =
  let code =
    match status with
    | `OK -> 200
    | `Bad_request -> 400
  in
  let cohttp_status =
    match status with
    | `OK -> `OK
    | `Bad_request -> `Bad_request
  in
  (code, `Response (Inbound_http.Response.json ~status:cohttp_status body))

let respond_rop ~error_to_string = function
  | Ok () -> json_response ~status:`OK success_body
  | Error errs ->
      let strings = List.map error_to_string errs in
      json_response ~status:`Bad_request (validation_body_of_strings strings)

let configure_risk_response configure_risk body : Inbound_http.Route.response =
  match parse_body CR.t_of_string body with
  | Error msg -> json_response ~status:`Bad_request (malformed_body ~msg)
  | Ok cmd -> respond_rop ~error_to_string:CRH.handle_error_to_string (configure_risk cmd)

let subscribe_book_to_alpha_response subscribe_book_to_alpha body :
    Inbound_http.Route.response =
  match parse_body SBA.t_of_string body with
  | Error msg -> json_response ~status:`Bad_request (malformed_body ~msg)
  | Ok cmd ->
      respond_rop ~error_to_string:SBAH.handle_error_to_string
        (subscribe_book_to_alpha cmd)

let define_pair_mr_response define_pair_mr body : Inbound_http.Route.response =
  match parse_body DPM.t_of_string body with
  | Error msg -> json_response ~status:`Bad_request (malformed_body ~msg)
  | Ok cmd ->
      respond_rop ~error_to_string:DPMH.handle_error_to_string (define_pair_mr cmd)

let define_pair_kalman_mr_response define_pair_kalman_mr body :
    Inbound_http.Route.response =
  match parse_body DPKM.t_of_string body with
  | Error msg -> json_response ~status:`Bad_request (malformed_body ~msg)
  | Ok cmd ->
      respond_rop ~error_to_string:DPKMH.handle_error_to_string
        (define_pair_kalman_mr cmd)

let make_handler
    ~configure_risk
    ~subscribe_book_to_alpha
    ~define_pair_mr
    ~define_pair_kalman_mr : Inbound_http.Route.handler =
 fun request body ->
  let uri = Cohttp.Request.uri request in
  let path = Uri.path uri in
  let meth = Cohttp.Request.meth request in
  match (meth, path) with
  | `POST, "/api/portfolio_management/risk_configs" ->
      Some (configure_risk_response configure_risk body)
  | `POST, "/api/portfolio_management/alpha_subscriptions" ->
      Some (subscribe_book_to_alpha_response subscribe_book_to_alpha body)
  | `POST, "/api/portfolio_management/pair_mr_policies" ->
      Some (define_pair_mr_response define_pair_mr body)
  | `POST, "/api/portfolio_management/pair_kalman_mr_policies" ->
      Some (define_pair_kalman_mr_response define_pair_kalman_mr body)
  | _ -> None
