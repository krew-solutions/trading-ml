/** Chaikin Volatility Indicator.
 *  spread_t = EMA(high - low, period)
 *  CVI_t    = 100 · (spread_t - spread_{t-period}) / spread_{t-period}
 *  Positive CVI means the high-low range is widening (rising volatility). */

import { ema } from './ema';
import type { OHLCV } from './ohlcv';

export function cvi(candles: OHLCV[], period = 10): number[] {
  const n = candles.length;
  const out = new Array<number>(n).fill(NaN);
  if (!n || period <= 0) return out;
  const ranges = candles.map(c => c.high - c.low);
  const spread = ema(ranges, period);
  for (let i = period; i < n; i++) {
    const prev = spread[i - period], curr = spread[i];
    if (!Number.isNaN(prev) && !Number.isNaN(curr) && prev !== 0) {
      out[i] = (100 * (curr - prev)) / prev;
    }
  }
  return out;
}
