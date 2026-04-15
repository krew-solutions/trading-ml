/** Minimal OHLCV shape consumed by indicators that need more than closes.
 *  Duck-typed so callers can pass either [[Candle]] from api.service or any
 *  structurally-compatible object without importing the UI service here.
 *  Keeping this independent avoids a dependency cycle with api.service. */

export interface OHLCV {
  open?: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}
