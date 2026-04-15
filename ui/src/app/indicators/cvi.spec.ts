import { describe, it, expect } from 'vitest';
import { cvi } from './cvi';
import type { OHLCV } from './ohlcv';

const bar = (high: number, low: number): OHLCV =>
  ({ high, low, close: (high + low) / 2, volume: 0 });

describe('cvi', () => {
  it('is ~0 when the high-low range is constant', () => {
    const cs = Array.from({ length: 30 }, () => bar(11, 10));
    const out = cvi(cs, 10);
    expect(out.at(-1)).toBeCloseTo(0, 6);
  });

  it('is positive when the range is widening', () => {
    const cs = Array.from({ length: 40 }, (_, i) => bar(10 + i * 0.5, 0));
    const out = cvi(cs, 10);
    expect(out.at(-1)!).toBeGreaterThan(0);
  });

  it('is negative when the range is narrowing', () => {
    const cs = Array.from({ length: 40 }, (_, i) => bar(30 - i * 0.5, 0));
    const out = cvi(cs, 10);
    expect(out.at(-1)!).toBeLessThan(0);
  });

  it('emits no value before enough history for the shift', () => {
    const cs = Array.from({ length: 5 }, () => bar(11, 10));
    expect(cvi(cs, 10).every(Number.isNaN)).toBe(true);
  });
});
