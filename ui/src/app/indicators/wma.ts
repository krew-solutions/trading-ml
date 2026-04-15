/** Weighted Moving Average: linear weights 1..period, weight sum = n(n+1)/2.
 *  Used standalone and as the smoothing kernel for MACD-Weighted. */

import {
  applyStyle, PRICE_PANE,
  type IndicatorOverlay, type OverlayBar, type OverlayStyle,
} from './overlay';

export function wma(data: number[], period: number): number[] {
  const out = new Array<number>(data.length).fill(NaN);
  if (!data.length || period <= 0) return out;
  const denom = (period * (period + 1)) / 2;
  for (let i = period - 1; i < data.length; i++) {
    let s = 0;
    for (let j = 0; j < period; j++) s += data[i - j] * (period - j);
    out[i] = s / denom;
  }
  return out;
}

export function wmaOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  style: OverlayStyle,
): IndicatorOverlay {
  const period = params['period'] || 20;
  const series = wma(bars.map(b => b.close), period);
  return {
    name: 'WMA',
    pane: PRICE_PANE,
    lines: [{
      label: `WMA(${period})`,
      color: style.color,
      ...applyStyle(style),
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
