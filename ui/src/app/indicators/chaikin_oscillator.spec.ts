import { describe, it, expect } from 'vitest';
import { chaikinOscillator } from './chaikin_oscillator';
import type { OHLCV } from './ohlcv';

const bar = (high: number, low: number, close: number, volume: number): OHLCV =>
  ({ high, low, close, volume });

describe('chaikinOscillator', () => {
  it('rejects fast >= slow', () => {
    expect(() => chaikinOscillator([], 10, 3)).toThrow();
  });

  it('collapses to zero when A/D is flat', () => {
    // All bars midrange → mfm = 0 → A/D flat at 0 → oscillator = 0.
    const cs = Array.from({ length: 30 }, () => bar(10, 0, 5, 100));
    const out = chaikinOscillator(cs, 3, 10);
    expect(out.at(-1)).toBeCloseTo(0, 6);
  });

  it('produces a defined value once both EMAs have seeded', () => {
    const cs = Array.from({ length: 40 }, (_, i) =>
      bar(10 + i, 0 + i, 5 + i + (i % 2), 100));
    const out = chaikinOscillator(cs, 3, 10);
    expect(Number.isNaN(out.at(-1))).toBe(false);
  });
});
