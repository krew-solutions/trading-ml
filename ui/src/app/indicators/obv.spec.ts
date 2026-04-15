import { describe, it, expect } from 'vitest';
import { obv } from './obv';
import type { OHLCV } from './ohlcv';

const bar = (close: number, volume: number): OHLCV => ({
  high: close, low: close, close, volume,
});

describe('obv', () => {
  it('starts at zero', () => {
    expect(obv([bar(100, 500)])[0]).toBe(0);
  });

  it('adds volume on up-close, subtracts on down-close', () => {
    const cs = [bar(100, 10), bar(101, 20), bar(100, 5), bar(101, 8)];
    expect(obv(cs)).toEqual([0, 20, 15, 23]);
  });

  it('ignores unchanged closes', () => {
    const cs = [bar(100, 10), bar(100, 99), bar(100, 42)];
    expect(obv(cs)).toEqual([0, 0, 0]);
  });
});
