(** Integration event: a strategy detected an actionable signal on a
    bar close.

    Carries a directional forecast — [UP] / [DOWN] / [FLAT] — together
    with a normalised [strength] in [0.0; 1.0]. The entry/exit
    distinction in {!Common.Signal.action} is *deliberately not*
    propagated across the BC boundary: strategy doesn't authoritatively
    know its position, so a bullish bar produces [direction = "UP"]
    regardless of whether the strategy thinks of it as opening a long
    or closing a short. The consumer (e.g. Portfolio Management's
    alpha-driven construction policy) decides what trade to make
    against its own [actual_portfolio].

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
          - [Enter_long]  / [Exit_short]  → ["UP"]
          - [Enter_short] / [Exit_long]   → ["DOWN"]
          - [Hold]                        → ["FLAT"]
       *)
  strength : float;  (** Strategy confidence, [0.0; 1.0]. *)
  price : string;
      (** Close of the bar that produced the signal, as a {!Decimal}
          string. Carried in the event itself so the consumer (alpha-
          driven portfolio construction) sizes against the *exact*
          price the strategy was looking at when it decided —
          eliminates the timing-join class of bugs that an external
          marks-cache would introduce. *)
  reason : string;  (** Free-form audit context from [Signal.reason]. *)
  occurred_at : int64;  (** Bar-close epoch seconds that triggered the signal. *)
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
