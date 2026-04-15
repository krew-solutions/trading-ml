/** Money Flow Index — volume-weighted RSI.
 *  typical_t = (h + l + c) / 3
 *  raw_money_flow = typical · volume
 *  positive_t = raw if typical_t > typical_{t-1} else 0
 *  negative_t = raw if typical_t < typical_{t-1} else 0
 *  MFI = 100 - 100 / (1 + sum(positive, n) / sum(negative, n))
 *  If the negative sum over the window is zero, MFI is defined as 100. */

import type { OHLCV } from './ohlcv';
import {
  applyStyle,
  type IndicatorOverlay, type OverlayBar, type OverlayStyle,
} from './overlay';

export function mfi(candles: OHLCV[], period = 14): number[] {
  const n = candles.length;
  const out = new Array<number>(n).fill(NaN);
  if (n < 2 || period <= 0) return out;

  const typical = candles.map(c => (c.high + c.low + c.close) / 3);
  const pos = new Array<number>(n).fill(0);
  const neg = new Array<number>(n).fill(0);
  for (let i = 1; i < n; i++) {
    const raw = typical[i] * candles[i].volume;
    if (typical[i] > typical[i - 1]) pos[i] = raw;
    else if (typical[i] < typical[i - 1]) neg[i] = raw;
  }
  // Running window sums starting at i = period (inclusive): window is
  // i-period+1 .. i, but raw is zero at position 0 anyway.
  let sumPos = 0, sumNeg = 0;
  for (let i = 1; i < n; i++) {
    sumPos += pos[i]; sumNeg += neg[i];
    if (i - period >= 1) {
      sumPos -= pos[i - period];
      sumNeg -= neg[i - period];
    }
    if (i >= period) {
      out[i] = sumNeg === 0 ? 100 : 100 - 100 / (1 + sumPos / sumNeg);
    }
  }
  return out;
}

export function mfiOverlay(
  bars: OverlayBar[],
  params: Record<string, number>,
  style: OverlayStyle,
): IndicatorOverlay {
  const period = params['period'] || 14;
  const series = mfi(bars, period);
  return {
    name: 'MFI',
    pane: 'mfi',
    lines: [{
      label: `MFI(${period})`,
      color: style.color,
      ...applyStyle(style),
      points: series.map((v, i) => ({ ts: bars[i].ts, v })),
    }],
  };
}
