import { describe, it, expect } from 'vitest';
import { cvd } from './cvd';
import type { OHLCV } from './ohlcv';

const bar = (high: number, low: number, close: number, volume: number): OHLCV =>
  ({ high, low, close, volume });

describe('cvd', () => {
  it('accumulates +volume when close sits at the high', () => {
    const cs = Array.from({ length: 5 }, () => bar(10, 0, 10, 100));
    expect(cvd(cs).at(-1)).toBe(500);
  });

  it('distributes -volume when close sits at the low', () => {
    const cs = Array.from({ length: 3 }, () => bar(10, 0, 0, 100));
    expect(cvd(cs).at(-1)).toBe(-300);
  });

  it('stays flat when close is at the midpoint', () => {
    const cs = Array.from({ length: 10 }, () => bar(10, 0, 5, 100));
    expect(cvd(cs).at(-1)).toBe(0);
  });

  it('treats zero range as zero delta (no divide-by-zero)', () => {
    expect(cvd([bar(10, 10, 10, 100)])[0]).toBe(0);
  });
});
