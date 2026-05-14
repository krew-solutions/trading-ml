(** Bar-against-order matching rules: decide whether an incoming
    candle triggers a fill for a working order, and at what price.

    Conventions (conservative, no-lookahead — favouring the trader
    on intra-bar prints):

    - [Market]: always fills at the bar's open. The implicit
      assumption is that the trader submitted before this bar's
      print, so [open_] is the first price they could have
      received.
    - [Limit lim], Buy: fills at [min open_ lim] if the bar gapped
      past the limit or touched it intra-bar; otherwise no fill.
    - [Limit lim], Sell: mirror of Buy on the upper side.
    - [Stop stop], Buy: triggers when the bar prints at or above
      [stop]; the fill price is the trigger if the bar gapped past
      it, or [stop] itself if it was touched intra-bar.
    - [Stop stop], Sell: mirror of Stop Buy on the lower side.
    - [Stop_limit _]: not simulated in this cut. Returns [None];
      the order stays in its working state.

    Returns the canonical (pre-slippage, pre-fee) fill price. *)

val price_if_filled :
  kind:Order.Values.Order_kind.t ->
  side:Core.Side.t ->
  candle:Core.Candle.t ->
  Decimal.t option
