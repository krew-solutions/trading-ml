/** Bollinger Bands: middle = SMA(n), upper = middle + k·σ, lower = middle - k·σ.
 *  σ is the population standard deviation of the window. O(n) via running sums
 *  of x and x². */

import {
  applyStyle, fade, PRICE_PANE,
  type IndicatorOverlay, type OverlayBar, type OverlayStyle,
} from './overlay';

export interface BBand {
  lower: number;
  middle: number;
  upper: number;
}

export function bollinger(data: number[], period: number, k: number): BBand[] {
  const out: BBand[] = data.map(() => ({ lower: NaN, middle: NaN, upper: NaN }));
  if (period <= 1 || k <= 0) return out;
  let sum = 0, sumSq = 0;
  for (let i = 0; i < data.length; i++) {
    sum += data[i];
    sumSq += data[i] * data[i];
    if (i >= period) {
      sum -= data[i - period];
      sumSq -= data[i - period] * data[i - period];
    }
    if (i >= period - 1) {
      const mean = sum / period;
      // Guard against catastrophic cancellation near constant inputs.
      const variance = Math.max(0, sumSq / period - mean * mean);
      const sd = Math.sqrt(variance);
      out[i] = { middle: mean, upper: mean + k * sd, lower: mean - k * sd };
    }
  }
  return out;
}

export function bollingerOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  style: OverlayStyle,
): IndicatorOverlay {
  const period = params['period'] || 20;
  const k = params['k'] || 2;
  const bands = bollinger(bars.map(b => b.close), period, k);
  const base = applyStyle(style);
  return {
    name: 'BB',
    pane: PRICE_PANE,
    lines: [
      { label: 'BB upper',  color: style.color,          ...base,
        points: bands.map((x, i) => ({ ts: bars[i].ts, v: x.upper })) },
      { label: 'BB middle', color: fade(style.color, 0.7), ...base,
        points: bands.map((x, i) => ({ ts: bars[i].ts, v: x.middle })) },
      { label: 'BB lower',  color: style.color,          ...base,
        points: bands.map((x, i) => ({ ts: bars[i].ts, v: x.lower })) },
    ],
  };
}
