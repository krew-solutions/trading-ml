import { describe, it, expect } from 'vitest';
import { volumeMa } from './volume_ma';
import type { OHLCV } from './ohlcv';

const bar = (volume: number): OHLCV =>
  ({ high: 1, low: 1, close: 1, volume });

describe('volumeMa', () => {
  it('returns NaN before the window is full', () => {
    const out = volumeMa([bar(100), bar(200)], 5);
    expect(out.every(Number.isNaN)).toBe(true);
  });

  it('is the arithmetic mean on a constant stream', () => {
    const out = volumeMa(Array.from({ length: 10 }, () => bar(500)), 5);
    expect(out.at(-1)).toBe(500);
  });

  it('slides the window correctly', () => {
    const cs = [bar(10), bar(20), bar(30), bar(60)];
    const out = volumeMa(cs, 3);
    expect(out[2]).toBeCloseTo(20);           // (10+20+30)/3
    expect(out[3]).toBeCloseTo(110 / 3);      // (20+30+60)/3
  });

  it('handles edge cases safely', () => {
    expect(volumeMa([], 5)).toEqual([]);
    expect(volumeMa([bar(10)], 0)).toEqual([NaN]);
  });
});
