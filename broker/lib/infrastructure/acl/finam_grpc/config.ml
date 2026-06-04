(** Endpoint configuration for the Finam Trade gRPC API.

    The gRPC endpoint is the same authoritative host as REST/WS — [api.finam.ru]
    — on :443 (TLS, ALPN h2). Authentication is the same two-step flow as the
    REST sibling, but expressed over gRPC: a long-lived portal [secret] is
    exchanged via [AuthService.Auth] for a short-lived JWT, which then travels in
    the [authorization] metadata of every other call. *)

type t = {
  host : string;
  port : int;
  secret : string;
  source_app_id : string;
      (** Optional source-app identifier echoed in [AuthRequest]; empty by
          default. *)
  default_mic : string option;
      (** Default MIC appended to bare tickers ([SBER] → [SBER@MISX]). Finam
          addresses instruments as [TICKER@MIC]. *)
}

let make
    ?(host = "api.finam.ru")
    ?(port = 443)
    ?(source_app_id = "")
    ?(default_mic = Some "MISX")
    ~secret
    () =
  { host; port; secret; source_app_id; default_mic }
