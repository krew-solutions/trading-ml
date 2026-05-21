include Open_order_ticket_command_t
include Open_order_ticket_command_j

type directive = Execution_directive_view_model.t = {
  kind : string;
  params : string option;
}
(** Type alias for the cross-referenced wire directive — keeps the
    handler's pattern-match expression aligned with the historical
    name ([directive]) while letting the wire field be
    [execution_directive] per ADR 0019's contract convention. *)

let yojson_of_t (v : t) : Yojson.Safe.t = Yojson.Safe.from_string (string_of_t v)
let t_of_yojson (j : Yojson.Safe.t) : t = t_of_string (Yojson.Safe.to_string j)
