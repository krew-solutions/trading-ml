/** MACD-Weighted: same shape as MACD but uses WMA (linear weights) instead of
 *  EMA for all three smoothing stages. WMA reacts faster to recent prices
 *  which some traders prefer for short-term signals. */

import { wma } from './wma';
import type { MACD } from './macd';
import {
  applyStyle, fade,
  type IndicatorOverlay, type OverlayBar, type OverlayStyle,
} from './overlay';

export function macdWeighted(
  data: number[],
  fast = 12,
  slow = 26,
  signalPeriod = 9,
): MACD[] {
  if (fast >= slow) {
    throw new Error(`MACD-W: fast (${fast}) must be < slow (${slow})`);
  }
  const fastW = wma(data, fast);
  const slowW = wma(data, slow);
  const macdLine = data.map((_, i) =>
    Number.isNaN(fastW[i]) || Number.isNaN(slowW[i])
      ? NaN : fastW[i] - slowW[i]);
  const firstValid = macdLine.findIndex(v => !Number.isNaN(v));
  const sigInput = firstValid < 0 ? [] : macdLine.slice(firstValid);
  const signalRaw = wma(sigInput, signalPeriod);
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

export function macdWeightedOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  style: OverlayStyle,
): IndicatorOverlay {
  const fast = params['fast'] || 12;
  const slow = params['slow'] || 26;
  const signal = params['signal'] || 9;
  const series = macdWeighted(bars.map(b => b.close), fast, slow, signal);
  const base = applyStyle(style);
  return {
    name: 'MACD-W',
    pane: 'macd-w',
    lines: [
      { label: 'MACD-W', color: style.color,              ...base,
        points: series.map((x, i) => ({ ts: bars[i].ts, v: x.macd })) },
      { label: 'Signal', color: fade(style.color, 0.55),  ...base,
        points: series.map((x, i) => ({ ts: bars[i].ts, v: x.signal })) },
      { label: 'Hist',   color: fade(style.color, 0.3),   ...base,
        points: series.map((x, i) => ({ ts: bars[i].ts, v: x.hist })) },
    ],
  };
}
