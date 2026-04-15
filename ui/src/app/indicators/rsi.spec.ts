import { describe, it, expect } from 'vitest';
import { rsi } from './rsi';

describe('rsi', () => {
  it('saturates to 100 on a strict uptrend (no losses)', () => {
    const data = Array.from({ length: 30 }, (_, i) => i + 1);
    const out = rsi(data, 14);
    expect(out.at(-1)).toBeCloseTo(100);
  });

  it('saturates to 0 on a strict downtrend (no gains)', () => {
    const data = Array.from({ length: 30 }, (_, i) => 30 - i);
    const out = rsi(data, 14);
    expect(out.at(-1)).toBeCloseTo(0);
  });

  it('hovers around 50 on a symmetric oscillation', () => {
    // Alternating ±1 moves: gains and losses are balanced, but Wilder's
    // recursive smoothing reacts to the sign of the last bar, so RSI
    // oscillates around (not at) 50.
    const data = Array.from({ length: 60 }, (_, i) => i % 2 === 0 ? 100 : 101);
    const v = rsi(data, 14).at(-1)!;
    expect(v).toBeGreaterThan(40);
    expect(v).toBeLessThan(60);
  });

  it('emits no value before the period is filled', () => {
    const out = rsi([1, 2, 3, 4, 5], 14);
    expect(out.every(Number.isNaN)).toBe(true);
  });
});
