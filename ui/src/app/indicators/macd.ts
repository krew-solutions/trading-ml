/** MACD (Moving Average Convergence Divergence).
 *  macd  = EMA(close, fast) - EMA(close, slow)
 *  signal = EMA(macd, signalPeriod)
 *  hist  = macd - signal
 *  Returned arrays share length with the input; positions before each
 *  component has enough data are NaN. */

import { ema } from './ema';
import { fade, type IndicatorOverlay, type OverlayBar } from './overlay';

export interface MACD {
  macd: number;
  signal: number;
  hist: number;
}

export function macd(
  data: number[],
  fast = 12,
  slow = 26,
  signalPeriod = 9,
): MACD[] {
  if (fast >= slow) {
    throw new Error(`MACD: fast (${fast}) must be < slow (${slow})`);
  }
  const fastEma = ema(data, fast);
  const slowEma = ema(data, slow);
  const macdLine = data.map((_, i) => {
    const f = fastEma[i], s = slowEma[i];
    return Number.isNaN(f) || Number.isNaN(s) ? NaN : f - s;
  });
  // Signal EMA must only start counting once macdLine itself emits.
  const firstValid = macdLine.findIndex(v => !Number.isNaN(v));
  const sigInput = firstValid < 0
    ? []
    : macdLine.slice(firstValid);
  const signalRaw = ema(sigInput, signalPeriod);
  const signalLine = new Array<number>(data.length).fill(NaN);
  if (firstValid >= 0) {
    for (let i = 0; i < signalRaw.length; i++) {
      signalLine[firstValid + i] = signalRaw[i];
    }
  }
  return data.map((_, i) => ({
    macd: macdLine[i],
    signal: signalLine[i],
    hist: Number.isNaN(macdLine[i]) || Number.isNaN(signalLine[i])
      ? NaN
      : macdLine[i] - signalLine[i],
  }));
}

export function macdOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  color: string,
): IndicatorOverlay {
  const fast = params['fast'] || 12;
  const slow = params['slow'] || 26;
  const signal = params['signal'] || 9;
  const series = macd(bars.map(b => b.close), fast, slow, signal);
  return {
    name: 'MACD',
    pane: 'macd',
    lines: [
      { label: 'MACD',   color,
        points: series.map((x, i) => ({ ts: bars[i].ts, v: x.macd })) },
      { label: 'Signal', color: fade(color, 0.55),
        points: series.map((x, i) => ({ ts: bars[i].ts, v: x.signal })) },
      { label: 'Hist',   color: fade(color, 0.3),
        points: series.map((x, i) => ({ ts: bars[i].ts, v: x.hist })) },
    ],
  };
}
