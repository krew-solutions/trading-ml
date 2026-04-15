/** Cumulative Volume Delta.
 *  Per-bar delta is estimated from the close's position within the range,
 *  since bar data carries no true bid/ask split:
 *    delta_t = volume · (2·close - high - low) / (high - low)
 *  giving +volume when close sits at the high, -volume at the low, 0 at
 *  the midpoint. CVD is the running sum of these deltas. Zero-range bars
 *  contribute zero delta to avoid division by zero. */

import type { OHLCV } from './ohlcv';

export function cvd(candles: OHLCV[]): number[] {
  const out = new Array<number>(candles.length);
  let sum = 0;
  for (let i = 0; i < candles.length; i++) {
    const { high, low, close, volume } = candles[i];
    const range = high - low;
    const delta = range === 0
      ? 0
      : (volume * (2 * close - high - low)) / range;
    sum += delta;
    out[i] = sum;
  }
  return out;
}
