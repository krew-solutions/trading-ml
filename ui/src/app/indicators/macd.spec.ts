import { describe, it, expect } from 'vitest';
import { macd } from './macd';

describe('macd', () => {
  it('rejects fast >= slow', () => {
    expect(() => macd([1, 2, 3], 26, 26, 9)).toThrow();
    expect(() => macd([1, 2, 3], 30, 26, 9)).toThrow();
  });

  it('collapses to zero on constant input', () => {
    const data = Array.from({ length: 100 }, () => 50);
    const out = macd(data, 12, 26, 9);
    const last = out.at(-1)!;
    expect(last.macd).toBeCloseTo(0, 6);
    expect(last.signal).toBeCloseTo(0, 6);
    expect(last.hist).toBeCloseTo(0, 6);
  });

  it('hist matches macd - signal where both are defined', () => {
    const data = Array.from({ length: 80 }, (_, i) =>
      100 + Math.sin(i / 5) * 10);
    for (const p of macd(data)) {
      if (!Number.isNaN(p.macd) && !Number.isNaN(p.signal)) {
        expect(p.hist).toBeCloseTo(p.macd - p.signal, 10);
      }
    }
  });
});
