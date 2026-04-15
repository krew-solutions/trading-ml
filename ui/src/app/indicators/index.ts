/** Barrel — single import surface for indicators, their overlays and types.
 *  Adding a new indicator = one file for the math + (optionally) an
 *  overlay function in the same file + one line here and one line in
 *  `overlay.ts`'s registry. */

// Shared types
export type { OHLCV } from './ohlcv';
export type {
  IndicatorOverlay, OverlayLine, OverlayBar, OverlayRenderer,
  OverlayStyle, OverlayPoint, LineStyle, LineWidth,
} from './overlay';
export {
  overlayRegistry, emptyOverlay, fade, withOpacity, applyStyle,
  LINE_STYLES, PRICE_PANE,
} from './overlay';

// Price-only indicators
export { sma, smaOverlay } from './sma';
export { ema, emaOverlay } from './ema';
export { wma, wmaOverlay } from './wma';
export { rsi, rsiOverlay } from './rsi';
export { bollinger, bollingerOverlay, type BBand } from './bollinger';
export { macd, macdOverlay, type MACD } from './macd';
export { macdWeighted, macdWeightedOverlay } from './macd_weighted';

// OHLCV indicators
export { atr, atrOverlay } from './atr';
export { obv, obvOverlay } from './obv';
export { ad, adOverlay } from './ad';
export {
  chaikinOscillator, chaikinOscillatorOverlay,
} from './chaikin_oscillator';
export { stochastic, stochasticOverlay, type Stoch } from './stochastic';
export { mfi, mfiOverlay } from './mfi';
export { cmf, cmfOverlay } from './cmf';
export { cvi, cviOverlay } from './cvi';
export { cvd, cvdOverlay } from './cvd';
export { volume, volumeOverlay } from './volume';
export { volumeMa, volumeMaOverlay } from './volume_ma';
