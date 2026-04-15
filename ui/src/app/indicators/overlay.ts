/** Overlay infrastructure: types and registry.
 *  Each indicator that renders onto the chart exports its own
 *  `<name>Overlay` function from its own file. The `pane` field
 *  determines where the lines are drawn:
 *    - 'price'    — the main price chart
 *    - any other  — a dedicated secondary pane identified by that key
 *  Two overlays sharing the same non-price pane key are stacked in
 *  the same secondary pane (e.g. MACD + Signal + Histogram). */

import type { OHLCV } from './ohlcv';
import { smaOverlay } from './sma';
import { emaOverlay } from './ema';
import { wmaOverlay } from './wma';
import { bollingerOverlay } from './bollinger';
import { rsiOverlay } from './rsi';
import { macdOverlay } from './macd';
import { macdWeightedOverlay } from './macd_weighted';
import { stochasticOverlay } from './stochastic';
import { volumeMaOverlay } from './volume_ma';
import { atrOverlay } from './atr';
import { mfiOverlay } from './mfi';
import { obvOverlay } from './obv';
import { adOverlay } from './ad';
import { cvdOverlay } from './cvd';
import { cmfOverlay } from './cmf';
import { cviOverlay } from './cvi';
import { chaikinOscillatorOverlay } from './chaikin_oscillator';

export interface OverlayBar extends OHLCV {
  ts: number;
}

export interface OverlayLine {
  label: string;
  color: string;
  points: { ts: number; v: number }[];
}

export interface IndicatorOverlay {
  name: string;
  /** Pane identifier. 'price' = main pane. Any other string creates or
   *  reuses a named secondary pane. */
  pane: string;
  lines: OverlayLine[];
}

export type OverlayRenderer = (
  bars: OverlayBar[],
  params: Record<string, number>,
  color: string,
) => IndicatorOverlay;

export const PRICE_PANE = 'price';

/** Map from indicator name (as reported by the OCaml catalog) to renderer.
 *  Indicators absent from this map are valid but not drawn. */
export const overlayRegistry: Record<string, OverlayRenderer> = {
  // Overlays on the main price pane
  'SMA': smaOverlay,
  'EMA': emaOverlay,
  'WMA': wmaOverlay,
  'BollingerBands': bollingerOverlay,
  // Oscillators / other-scale — each in its own secondary pane
  'RSI': rsiOverlay,
  'MACD': macdOverlay,
  'MACD-Weighted': macdWeightedOverlay,
  'Stochastic': stochasticOverlay,
  'MFI': mfiOverlay,
  'ATR': atrOverlay,
  'OBV': obvOverlay,
  'A/D': adOverlay,
  'CVD': cvdOverlay,
  'CMF': cmfOverlay,
  'CVI': cviOverlay,
  'ChaikinOscillator': chaikinOscillatorOverlay,
  'VolumeMA': volumeMaOverlay,
};

export function emptyOverlay(name: string): IndicatorOverlay {
  return { name, pane: PRICE_PANE, lines: [] };
}

/** Lighten a `#rrggbb` hex color by blending toward white.
 *  [alpha] = 1.0 → unchanged, 0.0 → full white. Used to de-emphasise
 *  secondary lines within a multi-line indicator (MACD signal/hist,
 *  Stochastic %D, etc.). */
export function fade(hex: string, alpha: number): string {
  const m = /^#([0-9a-f]{6})$/i.exec(hex);
  if (!m) return hex;
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 0xff, g = (n >> 8) & 0xff, b = n & 0xff;
  const blend = (c: number) => Math.round(c + (255 - c) * (1 - alpha));
  const h = (v: number) => v.toString(16).padStart(2, '0');
  return `#${h(blend(r))}${h(blend(g))}${h(blend(b))}`;
}
