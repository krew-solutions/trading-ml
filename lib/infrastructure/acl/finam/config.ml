(** Endpoint configuration for Finam Trade API.

    Authentication is a two-step flow (see Finam's getting-started docs):
      1. The user holds a long-lived [secret] issued on the portal.
      2. [POST /v1/sessions] with that secret returns a short-lived JWT.
      3. The JWT goes into [Authorization: Bearer] on every other call.
    [Finam.Auth] hides this behind a cache; consumers work with the JWT
    transparently. *)

type t = {
  rest_base : Uri.t;
  ws_url : Uri.t;
  secret : string;
  account_id : string option;
      (** Default Market Identifier Code (ISO 10383) appended to bare tickers.
      Finam's new API requires symbols in [TICKER@MIC] form, e.g.
      [SBER@MISX] for MOEX. Users that type just [SBER] get [MISX] by
      default; override here for other venues (e.g. [XNGS] for NASDAQ). *)
  default_mic : string option;
}

(* Authoritative host from the v2.14 REST docs is [api.finam.ru].
   [trade-api.finam.ru] and [tradeapi.finam.ru] are older / renamed hosts.
   WebSocket endpoint per asyncapi-v1.0.0.yaml: [/ws] on the same host. *)
let make
    ?(rest_base = Uri.of_string "https://api.finam.ru")
    ?(ws_url = Uri.of_string "wss://api.finam.ru/ws")
    ?account_id
    ?(default_mic = Some "MISX")
    ~secret
    () =
  { rest_base; ws_url; secret; account_id; default_mic }
