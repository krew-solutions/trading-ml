/** Chaikin Oscillator = EMA(A/D, fast) - EMA(A/D, slow).
 *  Measures momentum of the Accumulation/Distribution line. Defaults
 *  3 / 10 are Chaikin's originals. */

import { ad } from './ad';
import { ema } from './ema';
import type { OHLCV } from './ohlcv';
import type { IndicatorOverlay, OverlayBar } from './overlay';

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

export function chaikinOscillatorOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  color: string,
): IndicatorOverlay {
  const fast = params['fast'] || 3;
  const slow = params['slow'] || 10;
  const series = chaikinOscillator(bars, fast, slow);
  return {
    name: 'ChaikinOsc',
    pane: 'chaikin_osc',
    lines: [{
      label: `ChO(${fast},${slow})`,
      color,
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
