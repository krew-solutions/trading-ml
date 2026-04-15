import { describe, it, expect } from 'vitest';
import { macdWeighted } from './macd_weighted';
import { macd } from './macd';

describe('macdWeighted', () => {
  it('rejects fast >= slow', () => {
    expect(() => macdWeighted([1, 2, 3], 26, 26, 9)).toThrow();
  });

  it('collapses to zero on constant input', () => {
    const data = Array.from({ length: 100 }, () => 10);
    const out = macdWeighted(data, 5, 13, 4);
    const last = out.at(-1)!;
    expect(last.macd).toBeCloseTo(0, 10);
    expect(last.signal).toBeCloseTo(0, 10);
    expect(last.hist).toBeCloseTo(0, 10);
  });

  it('signs with the trend: positive macd on an uptrend, negative on down', () => {
    // Both MACD variants must agree on direction; magnitudes may differ
    // because slow EMA retains long memory while slow WMA forgets sharply.
    const up = Array.from({ length: 60 }, (_, i) => 100 + i);
    const down = Array.from({ length: 60 }, (_, i) => 160 - i);

    const wUp = macdWeighted(up, 5, 13, 4).at(-1)!;
    const sUp = macd(up, 5, 13, 4).at(-1)!;
    expect(wUp.macd).toBeGreaterThan(0);
    expect(sUp.macd).toBeGreaterThan(0);

    const wDown = macdWeighted(down, 5, 13, 4).at(-1)!;
    const sDown = macd(down, 5, 13, 4).at(-1)!;
    expect(wDown.macd).toBeLessThan(0);
    expect(sDown.macd).toBeLessThan(0);
  });
});
