(** Read-side projection of the full {!Pre_trade_risk.Risk_view.t}
    aggregate — diagnostic snapshot for HTTP / SSE consumers. *)

type t = {
  book_id : string;
  cash : string;
  positions : Position_snapshot_view_model.t list;
}
[@@deriving yojson]

type domain = Pre_trade_risk.Risk_view.t

val of_domain : domain -> t
