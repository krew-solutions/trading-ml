import { describe, it, expect } from 'vitest';
import { atr } from './atr';
import type { OHLCV } from './ohlcv';

const bar = (high: number, low: number, close: number): OHLCV => ({
  high, low, close, volume: 0,
});

describe('atr', () => {
  it('equals the high-low range when closes match and range is constant', () => {
    const cs = Array.from({ length: 30 }, () => bar(11, 10, 10.5));
    const out = atr(cs, 14);
    expect(out.at(-1)).toBeCloseTo(1);
  });

  it('reacts upward to a wider bar (volatility spike)', () => {
    const calm = Array.from({ length: 20 }, () => bar(11, 10, 10.5));
    const spike = [bar(20, 10, 15)];
    const out = atr([...calm, ...spike], 14);
    const before = out[19];
    const after  = out[20];
    expect(after).toBeGreaterThan(before);
  });

  it('emits no value before the period is filled', () => {
    const cs = Array.from({ length: 5 }, () => bar(2, 1, 1.5));
    expect(atr(cs, 14).every(Number.isNaN)).toBe(true);
  });
});
