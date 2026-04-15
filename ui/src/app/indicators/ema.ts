/** Exponential Moving Average.
 *  Seeded with the SMA of the first [period] samples, then recursively
 *  [ema_t = α·x_t + (1 - α)·ema_{t-1}], with α = 2/(period+1). */

import { PRICE_PANE, type IndicatorOverlay, type OverlayBar } from './overlay';

export function ema(data: number[], period: number): number[] {
  const out = new Array<number>(data.length).fill(NaN);
  if (!data.length || period <= 0) return out;
  const a = 2 / (period + 1);
  let seed = 0;
  let value: number | null = null;
  for (let i = 0; i < data.length; i++) {
    if (i < period - 1) { seed += data[i]; continue; }
    if (i === period - 1) { seed += data[i]; value = seed / period; }
    else value = a * data[i] + (1 - a) * (value as number);
    out[i] = value;
  }
  return out;
}

export function emaOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  color: string,
): IndicatorOverlay {
  const period = params['period'] || 20;
  const series = ema(bars.map(b => b.close), period);
  return {
    name: 'EMA',
    pane: PRICE_PANE,
    lines: [{
      label: `EMA(${period})`,
      color,
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
