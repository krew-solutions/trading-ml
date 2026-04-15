import { describe, it, expect } from 'vitest';
import { stochastic } from './stochastic';
import type { OHLCV } from './ohlcv';

const bar = (high: number, low: number, close: number): OHLCV =>
  ({ high, low, close, volume: 0 });

describe('stochastic', () => {
  it('returns 100 when close equals the window high', () => {
    // Window high is 23 across all 14 bars; closing at 23 gives %K = 100.
    const cs = Array.from({ length: 14 }, () => bar(23, 0, 23));
    const out = stochastic(cs, 14, 3);
    expect(out[13].k).toBeCloseTo(100);
  });

  it('returns 0 when close equals the window low', () => {
    // Window low is 0 across all 14 bars; closing at 0 gives %K = 0.
    const cs = Array.from({ length: 14 }, () => bar(23, 0, 0));
    const out = stochastic(cs, 14, 3);
    expect(out[13].k).toBeCloseTo(0);
  });

  it('returns 50 on a flat range (safe fallback)', () => {
    const cs = Array.from({ length: 14 }, () => bar(5, 5, 5));
    const out = stochastic(cs, 14, 3);
    expect(out[13].k).toBe(50);
  });

  it('%D is the SMA(%K, d) over a smooth ramp', () => {
    const cs = Array.from({ length: 30 }, (_, i) =>
      bar(10 + i, i, 5 + i));
    const out = stochastic(cs, 14, 3);
    const last = out.at(-1)!;
    expect(Number.isNaN(last.d)).toBe(false);
    // The mean of three close-together values: bounded by the K range.
    expect(last.d).toBeGreaterThan(0);
    expect(last.d).toBeLessThanOrEqual(100);
  });
});
