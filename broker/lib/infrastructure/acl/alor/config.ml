(** Endpoint configuration for the Alor Trade API (alor.dev).

    Authentication is an OAuth2 refresh-token flow:
      1. The user holds a long-lived [refresh_token] issued in the
         Alor developer portal.
      2. [POST {oauth_base}/refresh?token=<refresh_token>] returns a
         short-lived JWT in the [AccessToken] field.
      3. The JWT goes into [Authorization: Bearer] on every REST call,
         and into the [token] field of every WS subscribe message.
    [Alor.Auth] hides this behind a cache; consumers work with the
    JWT transparently.

    Unlike BCS's Keycloak, Alor does not rotate the refresh-token on
    exchange and returns no [expires_in] — the access JWT's own [exp]
    claim is the authoritative expiry. The refresh-token is therefore
    read once (env var) and never persisted, so no {!Token_store} is
    wired in here.

    {b Account identity.} Alor scopes every order/trade/position call
    by a [portfolio] code (e.g. ["D12345"]) plus an [exchange]
    (["MOEX"] | ["SPBX"]). [portfolio] is baked into the adapter at
    construction (an Alor user with several portfolios creates one
    [Broker.client] per portfolio); [exchange] is derived per request
    from the instrument's MIC, falling back to [default_exchange] for
    account-wide calls (the trades feed, which is not instrument-keyed). *)

type t = {
  api_base : Uri.t;
  oauth_base : Uri.t;
  ws_url : Uri.t;
  refresh_token : string;
  portfolio : string;
  default_exchange : string;
      (** Alor venue code used for account-wide calls (trades feed)
          and when an instrument's MIC has no mapping. ["MOEX"] |
          ["SPBX"]. *)
  default_board : string option;
      (** Board (Alor [instrumentGroup], e.g. ["TQBR"]) attached to
          order/subscribe requests when the instrument carries no
          board of its own. [None] lets Alor pick the primary board. *)
}

(* Authoritative hosts from alor.dev: REST on [api.alor.ru], OAuth on
   [oauth.alor.ru], WS subscriptions on [api.alor.ru/ws]. The [dev]
   sandbox swaps in [apidev.alor.ru] / [oauthdev.alor.ru]; override via
   the optional args for paper/sandbox testing. *)
let make
    ?(api_base = Uri.of_string "https://api.alor.ru")
    ?(oauth_base = Uri.of_string "https://oauth.alor.ru")
    ?(ws_url = Uri.of_string "wss://api.alor.ru/ws")
    ?(default_exchange = "MOEX")
    (* TQBR — MOEX T+ equities, the retail-trading norm and the board our
       public tape stamps onto every print (the AllTrades frame carries it).
       Surfaced through /api/exchanges so the UI subscribes with the
       board-qualified id by default, matching the published identity. *)
    ?(default_board = Some "TQBR")
    ~refresh_token
    ~portfolio
    () =
  {
    api_base;
    oauth_base;
    ws_url;
    refresh_token;
    portfolio;
    default_exchange;
    default_board;
  }
