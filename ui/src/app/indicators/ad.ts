/** Accumulation / Distribution Line (Williams).
 *  Money Flow Multiplier: mfm = ((close - low) - (high - close)) / (high - low)
 *  Money Flow Volume:     mfv = mfm · volume
 *  A/D is the running sum of mfv.  When high == low the multiplier is
 *  defined as 0 to avoid division by zero (standard convention). */

import type { OHLCV } from './ohlcv';

export function ad(candles: OHLCV[]): number[] {
  const out = new Array<number>(candles.length);
  let sum = 0;
  for (let i = 0; i < candles.length; i++) {
    const { high, low, close, volume } = candles[i];
    const range = high - low;
    const mfm = range === 0 ? 0 : ((close - low) - (high - close)) / range;
    sum += mfm * volume;
    out[i] = sum;
  }
  return out;
}
