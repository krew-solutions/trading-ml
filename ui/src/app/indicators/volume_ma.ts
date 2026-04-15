/** Volume Moving Average: SMA of bar volumes. Useful for flagging unusual
 *  volume (current bar vs. its own MA). Returns NaN for positions before
 *  the window is full. */

import type { OHLCV } from './ohlcv';
import {
  applyStyle,
  type IndicatorOverlay, type OverlayBar, type OverlayStyle,
} from './overlay';

export function volumeMa(candles: OHLCV[], period: number): number[] {
  const out = new Array<number>(candles.length).fill(NaN);
  if (!candles.length || period <= 0) return out;
  let sum = 0;
  for (let i = 0; i < candles.length; i++) {
    sum += candles[i].volume;
    if (i >= period) sum -= candles[i - period].volume;
    if (i >= period - 1) out[i] = sum / period;
  }
  return out;
}

export function volumeMaOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  style: OverlayStyle,
): IndicatorOverlay {
  const period = params['period'] || 20;
  const series = volumeMa(bars, period);
  return {
    name: 'VolumeMA',
    pane: 'volume',
    lines: [{
      label: `VolumeMA(${period})`,
      color: style.color,
      ...applyStyle(style),
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
