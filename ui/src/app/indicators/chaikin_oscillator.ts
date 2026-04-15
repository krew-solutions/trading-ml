/** Chaikin Oscillator = EMA(A/D, fast) - EMA(A/D, slow).
 *  Measures momentum of the Accumulation/Distribution line. Defaults
 *  3 / 10 are Chaikin's originals. */

import { ad } from './ad';
import { ema } from './ema';
import type { OHLCV } from './ohlcv';

export function chaikinOscillator(
  candles: OHLCV[],
  fast = 3,
  slow = 10,
): number[] {
  if (fast >= slow) {
    throw new Error(`ChaikinOsc: fast (${fast}) must be < slow (${slow})`);
  }
  const line = ad(candles);
  const fastEma = ema(line, fast);
  const slowEma = ema(line, slow);
  return line.map((_, i) =>
    Number.isNaN(fastEma[i]) || Number.isNaN(slowEma[i])
      ? NaN : fastEma[i] - slowEma[i]);
}
