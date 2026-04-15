import { describe, it, expect } from 'vitest';
import { ad } from './ad';
import type { OHLCV } from './ohlcv';

const bar = (high: number, low: number, close: number, volume: number): OHLCV =>
  ({ high, low, close, volume });

describe('ad', () => {
  it('adds full volume on a close at the high', () => {
    const cs = [bar(10, 5, 10, 100), bar(10, 5, 10, 100)];
    // mfm = ((10-5) - (10-10)) / 5 = 1 → mfv = 100 each
    expect(ad(cs)).toEqual([100, 200]);
  });

  it('subtracts full volume on a close at the low', () => {
    const cs = [bar(10, 5, 5, 100)];
    // mfm = ((5-5) - (10-5)) / 5 = -1
    expect(ad(cs)[0]).toBe(-100);
  });

  it('is zero at midpoint close', () => {
    const cs = [bar(10, 0, 5, 100)];
    // mfm = ((5-0) - (10-5)) / 10 = 0
    expect(ad(cs)[0]).toBe(0);
  });

  it('treats zero range as zero multiplier (no divide-by-zero)', () => {
    const cs = [bar(10, 10, 10, 100)];
    expect(ad(cs)[0]).toBe(0);
  });
});
