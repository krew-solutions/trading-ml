/** Average True Range (Wilder).
 *  TR_t = max(high - low, |high - prev_close|, |low - prev_close|).
 *  ATR_t = ((n-1)·ATR_{t-1} + TR_t) / n, seeded by mean of first [period] TRs. */

import type { OHLCV } from './ohlcv';
import type { IndicatorOverlay, OverlayBar } from './overlay';

export function atr(candles: OHLCV[], period = 14): number[] {
  const n = candles.length;
  const out = new Array<number>(n).fill(NaN);
  if (n < 2 || period <= 0) return out;

  const trs: number[] = new Array(n).fill(NaN);
  for (let i = 1; i < n; i++) {
    const c = candles[i], p = candles[i - 1];
    trs[i] = Math.max(
      c.high - c.low,
      Math.abs(c.high - p.close),
      Math.abs(c.low - p.close),
    );
  }

  let seed = 0;
  let value = NaN;
  for (let i = 1; i < n; i++) {
    if (i <= period) {
      seed += trs[i];
      if (i === period) { value = seed / period; out[i] = value; }
    } else {
      value = (value * (period - 1) + trs[i]) / period;
      out[i] = value;
    }
  }
  return out;
}

export function atrOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  color: string,
): IndicatorOverlay {
  const period = params['period'] || 14;
  const series = atr(bars, period);
  return {
    name: 'ATR',
    pane: 'atr',
    lines: [{
      label: `ATR(${period})`,
      color,
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
