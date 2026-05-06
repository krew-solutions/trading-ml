(** Domain Strategy: per-instrument margin terms.

    Resolves an instrument to the rates the aggregate uses when
    deciding (a) how much collateral a new short blocks, and
    (b) how much an existing long contributes to buying power.
    Implementations stay pure-domain — different algorithms or
    rate sources, but no IO inside this signature. *)

type margin_terms = {
  margin_pct : Decimal.t;
      (** Initial margin as a fraction of notional that a new short
          (or any leveraged open) must post as collateral. Used by
          {!Account.Portfolio.try_reserve} on the Sell-open path:
          [collateral = open_qty × price × margin_pct]. *)
  haircut : Decimal.t;
      (** Fraction of an existing long's mark value that counts as
          buying power for further leveraged opens. Used by
          {!Account.Portfolio.buying_power}: a long worth N at mark
          contributes [N × haircut] to the available margin. *)
}

type t = Core.Instrument.t -> margin_terms
(** Pure lookup. The caller (composition root or test harness)
    plugs in the concrete strategy — a constant for the reference
    stub, a static table for known instruments, or in the future
    an HTTP-fetched live rate. *)

val constant : margin_pct:Decimal.t -> haircut:Decimal.t -> t
(** Stub strategy: every instrument receives the same terms. Useful
    in composition roots that don't have a live rate source yet, and
    in tests that don't need per-instrument variation. *)
