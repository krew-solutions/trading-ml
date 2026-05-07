(** Integration event: a strategy detected an actionable signal on a
    bar close.

    Carries a directional forecast — [UP] / [DOWN] / [FLAT] — together
    with a normalised [strength] in [0.0; 1.0]. The forecast is a
    declarative alpha-mind: [UP] / [DOWN] state the strategy's current
    directional opinion, [FLAT] states the absence of one. Bracket
    exits ({!Common.Signal.Exit_long} / {!Common.Signal.Exit_short}),
    fired when a TP / SL / timeout barrier resolves a previously-opened
    position, are alpha-expiry events: they project to [FLAT] (the
    strategy withdraws its view), with the outcome recorded verbatim
    in [reason] for downstream telemetry. The consumer (e.g. Portfolio
    Management's alpha-driven construction policy) translates [FLAT]
    into a zero target on the corresponding book; cancelling in-flight
    orders against the obsolete target is execution-layer work, not
    alpha's.

    DTO-shaped: primitives + nested view model, no domain values.
    [@@deriving yojson] auto-generates the on-wire format. *)

type t = {
  strategy_id : string;
      (** Identifier of the strategy instance that emitted the signal.
          Consumed by Portfolio Management's alpha-driven policy to
          route the signal to the matching policy state (multiple
          strategies may run on the same instrument). Not present in
          [Signal.t]; supplied by the publishing layer. *)
  instrument : Queries.Instrument_view_model.t;
  direction : string;
      (** Projected from {!Common.Signal.action}:
          - [Enter_long]                  → ["UP"]
          - [Enter_short]                 → ["DOWN"]
          - [Exit_long]  / [Exit_short]   → ["FLAT"] (alpha-expiry; outcome carried in [reason])
          - [Hold]                        → ["FLAT"]

          For [FLAT] originating from a bracket exit, [reason] carries
          the outcome label ("SL hit" / "TP hit" / "timeout") for
          downstream telemetry; consumers MUST NOT switch on [reason]
          for trading decisions. *)
  strength : float;  (** Strategy confidence, [0.0; 1.0]. *)
  price : string;
      (** Close of the bar that produced the signal, as a {!Decimal}
          string. Carried in the event itself so the consumer (alpha-
          driven portfolio construction) sizes against the *exact*
          price the strategy was looking at when it decided —
          eliminates the timing-join class of bugs that an external
          marks-cache would introduce. *)
  reason : string;  (** Free-form audit context from [Signal.reason]. *)
  occurred_at : string;
      (** ISO-8601 datetime ([YYYY-MM-DDTHH:MM:SSZ]) of the bar close
          that triggered the signal. *)
}
[@@deriving yojson]

type domain = Signal.t

val of_domain : strategy_id:string -> price:Decimal.t -> domain -> t
(** [strategy_id] and [price] are supplied by the publishing layer
    (composition root) because [Signal.t] itself carries neither —
    [strategy_id] is composition metadata and [price] is the bar-close
    the strategy was looking at when it decided.

    [book_id] is deliberately absent: it is a Portfolio Management
    concept, not strategy's. The mapping
    [(strategy_id, instrument) → book_id] lives in PM's configuration
    and is applied by PM's inbound ACL handler when projecting this
    IE into a target update. Including [book_id] here would leak PM's
    vocabulary into strategy's outbound contract. *)
