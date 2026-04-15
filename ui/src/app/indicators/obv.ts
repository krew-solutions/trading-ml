/** On-Balance Volume.
 *  OBV_0 = 0. For i > 0:
 *    close_i > close_{i-1} → OBV_i = OBV_{i-1} + volume_i
 *    close_i < close_{i-1} → OBV_i = OBV_{i-1} - volume_i
 *    otherwise             → OBV_i = OBV_{i-1} */

import type { OHLCV } from './ohlcv';
import {
  applyStyle,
  type IndicatorOverlay, type OverlayBar, type OverlayStyle,
} from './overlay';

export function obv(candles: OHLCV[]): number[] {
  const n = candles.length;
  const out = new Array<number>(n);
  if (n === 0) return out;
  out[0] = 0;
  for (let i = 1; i < n; i++) {
    const sign =
      candles[i].close > candles[i - 1].close ? +1 :
      candles[i].close < candles[i - 1].close ? -1 : 0;
    out[i] = out[i - 1] + sign * candles[i].volume;
  }
  return out;
}

export function obvOverlay(
  bars: OverlayBar[],
  _params: Record<string, number>,
  style: OverlayStyle,
): IndicatorOverlay {
  const series = obv(bars);
  return {
    name: 'OBV',
    pane: 'obv',
    lines: [{
      label: 'OBV',
      color: style.color,
      ...applyStyle(style),
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
