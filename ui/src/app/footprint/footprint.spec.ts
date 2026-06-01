import { describe, it, expect } from 'vitest';
import {
  cvdTrue, parseDelta, parseOpenTs, parseCluster,
  clusterCells, cellColor,
  type FootprintBar, type FootprintCluster,
} from './footprint';

const bar = (ts: number, delta: number): FootprintBar =>
  ({ ts, delta, clusters: [] });

const cluster = (
  price: number, buy: number, sell: number, indeterminate = 0,
): FootprintCluster => ({ price, buy, sell, indeterminate });

const barWith = (ts: number, clusters: FootprintCluster[]): FootprintBar =>
  ({ ts, delta: 0, clusters });

describe('cvdTrue', () => {
  it('is the running sum of measured per-bar deltas', () => {
    const bars = [bar(1, 5), bar(2, -3), bar(3, 2)];
    // unlike the candle proxy, the delta is taken verbatim, not estimated
    expect(cvdTrue(bars)).toEqual([5, 2, 4]);
  });

  it('anchors at 0 before the first bar', () => {
    expect(cvdTrue([bar(1, 7)])).toEqual([7]);
  });

  it('handles an empty window', () => {
    expect(cvdTrue([])).toEqual([]);
  });

  it('preserves negative cumulative excursions', () => {
    expect(cvdTrue([bar(1, -2), bar(2, -3)])).toEqual([-2, -5]);
  });
});

describe('parseDelta', () => {
  it('parses a signed decimal-string delta into a number', () => {
    expect(parseDelta('-2')).toBe(-2);
    expect(parseDelta('15.5')).toBe(15.5);
  });
});

describe('parseOpenTs', () => {
  it('converts ISO-8601 to unix epoch seconds', () => {
    expect(parseOpenTs('1970-01-01T00:00:00Z')).toBe(0);
    expect(parseOpenTs('2024-01-15T10:00:00Z')).toBe(Date.UTC(2024, 0, 15, 10) / 1000);
  });
});

describe('parseCluster', () => {
  it('projects decimal-string buckets into numbers', () => {
    expect(parseCluster({
      price: '100.5', buy_volume: '7', sell_volume: '3',
      indeterminate_volume: '2',
    })).toEqual({ price: 100.5, buy: 7, sell: 3, indeterminate: 2 });
  });
});

describe('clusterCells', () => {
  it('normalises intensity against the busiest cell in the window', () => {
    const cells = clusterCells([
      barWith(1, [cluster(100, 10, 0), cluster(101, 5, 0)]), // totals 10, 5
      barWith(2, [cluster(100, 0, 20)]),                     // total 20 (busiest)
    ]);
    const byKey = new Map(cells.map(c => [`${c.ts}:${c.price}`, c]));
    expect(byKey.get('1:100')!.intensity).toBeCloseTo(0.5); // 10/20
    expect(byKey.get('1:101')!.intensity).toBeCloseTo(0.25); // 5/20
    expect(byKey.get('2:100')!.intensity).toBe(1);           // 20/20
  });

  it('carries total and signed delta per cell', () => {
    const [c] = clusterCells([barWith(1, [cluster(100, 7, 3, 2)])]);
    expect(c.total).toBe(12);   // 7 + 3 + 2
    expect(c.delta).toBe(4);    // 7 − 3 (indeterminate excluded)
  });

  it('drops empty levels and yields nothing for an all-empty grid', () => {
    expect(clusterCells([barWith(1, [cluster(100, 0, 0, 0)])])).toEqual([]);
    expect(clusterCells([])).toEqual([]);
  });
});

describe('cellColor', () => {
  const cell = (delta: number, intensity: number) =>
    ({ ts: 0, price: 0, total: 1, delta, intensity });

  it('is green-ish when buyers dominate, red-ish when sellers do', () => {
    expect(cellColor(cell(5, 0.5))).toContain('38,166,154');
    expect(cellColor(cell(-5, 0.5))).toContain('239,83,80');
    expect(cellColor(cell(0, 0.5))).toContain('120,120,120');
  });

  it('scales alpha with intensity within a visible, legible band', () => {
    const lo = cellColor(cell(5, 0)).match(/,([\d.]+)\)$/)![1];
    const hi = cellColor(cell(5, 1)).match(/,([\d.]+)\)$/)![1];
    expect(Number(lo)).toBeCloseTo(0.15); // floor: light cells stay visible
    expect(Number(hi)).toBeCloseTo(0.8);  // cap < 1: candles stay legible
    expect(Number(hi)).toBeGreaterThan(Number(lo));
  });
});
