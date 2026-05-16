(** Read-model DTO for {!Core.Candle.t}.

    OHLCV as primitives: [ts] is an ISO-8601 datetime string
    ([YYYY-MM-DDTHH:MM:SSZ]) for cross-language wire-format
    consistency with the rest of the BC's commands and integration
    events; prices/volume are decimal strings accepted by
    {!Decimal.of_string} — bit-exact round-trip with the domain. *)

type t = {
  ts : string;  (** ISO-8601 *)
  open_ : string; [@key "open"]
  high : string;
  low : string;
  close : string;
  volume : string;
}
[@@deriving yojson]

type domain = Core.Candle.t

val of_domain : domain -> t
