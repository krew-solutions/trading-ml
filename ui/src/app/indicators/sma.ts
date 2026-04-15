/** Simple Moving Average — arithmetic mean of the last [period] samples.
 *  Returns NaN for positions before the window is full. O(n) time, O(1) extra
 *  state via a running sum. */

import { PRICE_PANE, type IndicatorOverlay, type OverlayBar } from './overlay';

export function sma(data: number[], period: number): number[] {
  const out = new Array<number>(data.length).fill(NaN);
  if (!data.length || period <= 0) return out;
  let sum = 0;
  for (let i = 0; i < data.length; i++) {
    sum += data[i];
    if (i >= period) sum -= data[i - period];
    if (i >= period - 1) out[i] = sum / period;
  }
  return out;
}

export function smaOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  color: string,
): IndicatorOverlay {
  const period = params['period'] || 20;
  const series = sma(bars.map(b => b.close), period);
  return {
    name: 'SMA',
    pane: PRICE_PANE,
    lines: [{
      label: `SMA(${period})`,
      color,
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
