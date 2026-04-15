import { describe, it, expect } from 'vitest';
import { wma } from './wma';

describe('wma', () => {
  it('weights recent bars more heavily than old ones', () => {
    // WMA(3) of [1, 2, 6]: (1·1 + 2·2 + 6·3) / 6 = 23/6
    const out = wma([1, 2, 6], 3);
    expect(out[0]).toBeNaN();
    expect(out[1]).toBeNaN();
    expect(out[2]).toBeCloseTo(23 / 6);
  });

  it('equals the input on constant data', () => {
    const out = wma([5, 5, 5, 5, 5], 3);
    expect(out[2]).toBeCloseTo(5);
    expect(out[4]).toBeCloseTo(5);
  });

  it('handles edge cases safely', () => {
    expect(wma([], 5)).toEqual([]);
    expect(wma([1, 2], 0)).toEqual([NaN, NaN]);
  });
});
