/** Volume histogram.
 *  No actual math — just lifts per-bar volumes and tags each bar as bullish
 *  or bearish based on intra-bar close vs. open, which is the TradingView
 *  convention. Renders as a [HistogramSeries] in the 'volume' pane. */

import type { OHLCV } from './ohlcv';
import type {
  IndicatorOverlay, OverlayBar, OverlayStyle,
} from './overlay';

export function volume(candles: OHLCV[]): number[] {
  return candles.map(c => c.volume);
}

const UP   = '#26a69a';
const DOWN = '#ef5350';

export function volumeOverlay(
  bars: OverlayBar[],
  _params: Record<string, number>,
  style: OverlayStyle,
): IndicatorOverlay {
  return {
    name: 'Volume',
    pane: 'volume',
    lines: [{
      label: 'Volume',
      color: UP,             // legend swatch — per-point colors override
      kind: 'histogram',
      opacity: style.opacity,
      points: bars.map(b => ({
        ts: b.ts,
        v: b.volume,
        color: (b.open !== undefined && b.close < b.open) ? DOWN : UP,
      })),
    }],
  };
}
