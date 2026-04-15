/** Stochastic Oscillator (%K, %D).
 *  %K = 100 · (close - lowest_low_n) / (highest_high_n - lowest_low_n)
 *  %D = SMA(%K, dPeriod) — the "slow" signal line
 *  Default periods: K=14, D=3. When the high-low range collapses to zero
 *  the indicator is defined as 50 (midpoint). */

import { sma } from './sma';
import type { OHLCV } from './ohlcv';

export interface Stoch { k: number; d: number; }

export function stochastic(
  candles: OHLCV[],
  kPeriod = 14,
  dPeriod = 3,
): Stoch[] {
  const n = candles.length;
  const kLine = new Array<number>(n).fill(NaN);
  for (let i = kPeriod - 1; i < n; i++) {
    let hi = -Infinity, lo = +Infinity;
    for (let j = i - kPeriod + 1; j <= i; j++) {
      if (candles[j].high > hi) hi = candles[j].high;
      if (candles[j].low  < lo) lo = candles[j].low;
    }
    const range = hi - lo;
    kLine[i] = range === 0 ? 50 : (100 * (candles[i].close - lo)) / range;
  }
  // %D is SMA of %K ignoring the leading NaNs.
  const firstValid = kLine.findIndex(v => !Number.isNaN(v));
  const dLine = new Array<number>(n).fill(NaN);
  if (firstValid >= 0) {
    const slice = kLine.slice(firstValid);
    const smaSlice = sma(slice, dPeriod);
    for (let i = 0; i < smaSlice.length; i++) dLine[firstValid + i] = smaSlice[i];
  }
  return candles.map((_, i) => ({ k: kLine[i], d: dLine[i] }));
}
