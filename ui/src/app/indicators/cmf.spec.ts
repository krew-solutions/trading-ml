import { describe, it, expect } from 'vitest';
import { cmf } from './cmf';
import type { OHLCV } from './ohlcv';

const bar = (high: number, low: number, close: number, volume: number): OHLCV =>
  ({ high, low, close, volume });

describe('cmf', () => {
  it('is +1 when every close hits the high', () => {
    const cs = Array.from({ length: 25 }, () => bar(10, 0, 10, 100));
    expect(cmf(cs, 20).at(-1)).toBeCloseTo(1);
  });

  it('is -1 when every close hits the low', () => {
    const cs = Array.from({ length: 25 }, () => bar(10, 0, 0, 100));
    expect(cmf(cs, 20).at(-1)).toBeCloseTo(-1);
  });

  it('sits near zero when closes alternate high/low equally', () => {
    const cs = Array.from({ length: 40 }, (_, i) =>
      i % 2 === 0 ? bar(10, 0, 10, 100) : bar(10, 0, 0, 100));
    expect(cmf(cs, 20).at(-1)!).toBeCloseTo(0, 6);
  });

  it('emits no value before the window is filled', () => {
    const cs = Array.from({ length: 5 }, () => bar(10, 0, 5, 100));
    expect(cmf(cs, 20).every(Number.isNaN)).toBe(true);
  });
});
