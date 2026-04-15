/** Chaikin Money Flow.
 *  mfm_t = ((close - low) - (high - close)) / (high - low)   (0 if range=0)
 *  mfv_t = mfm_t · volume_t
 *  CMF_t = sum(mfv, period) / sum(volume, period)
 *  Values range roughly in [-1; 1]; positive = accumulation. */

import type { OHLCV } from './ohlcv';
import {
  applyStyle,
  type IndicatorOverlay, type OverlayBar, type OverlayStyle,
} from './overlay';

export function cmf(candles: OHLCV[], period = 20): number[] {
  const n = candles.length;
  const out = new Array<number>(n).fill(NaN);
  if (!n || period <= 0) return out;
  const mfv = new Array<number>(n);
  const vol = new Array<number>(n);
  for (let i = 0; i < n; i++) {
    const { high, low, close, volume } = candles[i];
    const range = high - low;
    const mfm = range === 0 ? 0 : ((close - low) - (high - close)) / range;
    mfv[i] = mfm * volume;
    vol[i] = volume;
  }
  let sMfv = 0, sVol = 0;
  for (let i = 0; i < n; i++) {
    sMfv += mfv[i]; sVol += vol[i];
    if (i >= period) { sMfv -= mfv[i - period]; sVol -= vol[i - period]; }
    if (i >= period - 1) out[i] = sVol === 0 ? 0 : sMfv / sVol;
  }
  return out;
}

export function cmfOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  style: OverlayStyle,
): IndicatorOverlay {
  const period = params['period'] || 20;
  const series = cmf(bars, period);
  return {
    name: 'CMF',
    pane: 'cmf',
    lines: [{
      label: `CMF(${period})`,
      color: style.color,
      ...applyStyle(style),
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
