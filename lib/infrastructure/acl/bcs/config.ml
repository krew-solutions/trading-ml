(** BCS Trade API endpoint config.

    Authentication is OAuth2 refresh-token flow served by a Keycloak
    realm. The user holds a long-lived *refresh_token*; every so often
    it must be exchanged for a short-lived *access_token* that goes
    into [Authorization: Bearer …] on API calls. [Bcs.Auth] handles
    the exchange and caches the access token.

    [token_endpoint] is the Keycloak `…/protocol/openid-connect/token`
    URL. The default was picked from the [iss] claim observed in a
    real refresh_token; override if BCS moves realms. *)

type t = {
  rest_base : Uri.t;
  token_endpoint : Uri.t;
  client_id : string;
  refresh_token : string;
  account_id : string option;
  (** BCS identifies instruments by (classCode, ticker) rather than a
      single composite symbol. When the UI sends a bare ticker ("SBER")
      we fall back to this class code. Default [TQBR] is the MOEX
      T+ stocks board, i.e. the retail-trading norm. *)
  default_class_code : string;
  (** WebSocket endpoint for the multiplexed market-data stream —
      one socket serves BARS, QUOTES, ORDER_BOOK subscriptions
      together, distinguished by a [type] field in the subscribe
      envelope. Previously BCS shipped a path per subscription kind
      ({[/last-candle/ws]}, {[/quotes/ws]}, …); the [bcs-trade-go]
      reference client still reflects the old layout. *)
  ws_market_data_url : Uri.t;
}

(* Public auth host is [be.broker.ru] per the BCS docs. [rest_base]
   for the data endpoints (bars, orders …) is a working hypothesis —
   the docs site lives at [trade-api.bcs.ru/http] but geoblocks
   datacenter IPs, so the real API is almost certainly colocated at
   [be.broker.ru]. Override via [?rest_base] if it diverges.

   WebSocket host is [ws.broker.ru] per the [bcs-trade-go] reference
   implementation. *)
let make
    ?(rest_base = Uri.of_string "https://be.broker.ru")
    ?(token_endpoint = Uri.of_string
        "https://be.broker.ru/trade-api-keycloak/realms/tradeapi\
         /protocol/openid-connect/token")
    ?(client_id = "trade-api-read")
    ?account_id
    ?(default_class_code = "TQBR")
    ?(ws_market_data_url = Uri.of_string
        "wss://ws.broker.ru/trade-api-market-data-connector/api/v1\
         /market-data/ws")
    ~refresh_token
    () =
  { rest_base; token_endpoint; client_id; refresh_token; account_id;
    default_class_code; ws_market_data_url }
