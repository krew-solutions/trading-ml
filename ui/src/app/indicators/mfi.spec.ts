import { describe, it, expect } from 'vitest';
import { mfi } from './mfi';
import type { OHLCV } from './ohlcv';

const bar = (high: number, low: number, close: number, volume: number): OHLCV =>
  ({ high, low, close, volume });

describe('mfi', () => {
  it('saturates to 100 when every bar rises', () => {
    const cs = Array.from({ length: 30 }, (_, i) =>
      bar(100 + i + 1, 100 + i - 1, 100 + i, 1000));
    const out = mfi(cs, 14);
    expect(out.at(-1)).toBeCloseTo(100);
  });

  it('saturates to 0 when every bar falls', () => {
    const cs = Array.from({ length: 30 }, (_, i) =>
      bar(100 - i + 1, 100 - i - 1, 100 - i, 1000));
    const out = mfi(cs, 14);
    expect(out.at(-1)).toBeCloseTo(0);
  });

  it('emits no value before the window is filled', () => {
    const cs = Array.from({ length: 5 }, (_, i) =>
      bar(i + 2, i, i + 1, 100));
    expect(mfi(cs, 14).every(Number.isNaN)).toBe(true);
  });
});
