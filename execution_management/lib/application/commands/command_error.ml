type t =
  | Ticket_not_found of int
  | Invalid_payload of string
  | Domain_violation of string

let to_string = function
  | Ticket_not_found id ->
      Printf.sprintf "ticket_not_found: ticket_id=%d" id
  | Invalid_payload msg -> "invalid_payload: " ^ msg
  | Domain_violation msg -> "domain_violation: " ^ msg
