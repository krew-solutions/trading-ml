import { describe, it, expect } from 'vitest';
import {
  cvdTrue, parseDelta, parseOpenTs, parseCluster,
  clusterCells, cellColor, cellRects, fmtVol,
  type FootprintBar, type FootprintCluster, type GridProjection,
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

  it('carries total, signed delta and the raw buy/sell per cell', () => {
    const [c] = clusterCells([barWith(1, [cluster(100, 7, 3, 2)])]);
    expect(c.total).toBe(12);   // 7 + 3 + 2
    expect(c.delta).toBe(4);    // 7 − 3 (indeterminate excluded)
    expect(c.buy).toBe(7);      // raw, for the in-cell labels
    expect(c.sell).toBe(3);
  });

  it('drops empty levels and yields nothing for an all-empty grid', () => {
    expect(clusterCells([barWith(1, [cluster(100, 0, 0, 0)])])).toEqual([]);
    expect(clusterCells([])).toEqual([]);
  });
});

describe('cellColor', () => {
  const cell = (delta: number, intensity: number) =>
    ({
      ts: 0, price: 0, total: 1, delta, intensity,
      buy: Math.max(delta, 0), sell: Math.max(-delta, 0),
    });

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

describe('cellRects', () => {
  // Linear projections: price p → y = 1000 − p (higher price = smaller y,
  // like a screen), ts → x = ts. barWidth 10.
  const proj: GridProjection = {
    timeToX: (ts) => ts,
    priceToY: (p) => 1000 - p,
    barWidth: 10,
  };

  it('centres a barWidth-wide column on the bar and the level on its price', () => {
    const cells = clusterCells([barWith(50, [cluster(100, 5, 1)])]);
    const [r] = cellRects(cells, proj);
    // x centred on ts=50, width 10 → x = 45; y centred on price 100 → y=900±h/2
    expect(r.w).toBe(10);
    expect(r.x).toBe(45);
    expect(r.y + r.h / 2).toBeCloseTo(900); // centre at priceToY(100)=900
  });

  it('sizes a level height by the gap to its neighbour on the same bar', () => {
    // two levels 100 and 105 → y 900 and 895, gap 5px
    const cells = clusterCells([
      barWith(50, [cluster(100, 5, 0), cluster(105, 3, 0)]),
    ]);
    const rects = cellRects(cells, proj);
    expect(rects).toHaveLength(2);
    expect(rects[0].h).toBeCloseTo(5);
    expect(rects[1].h).toBeCloseTo(5);
  });

  it('falls back to defaultPriceH for a lone level', () => {
    const cells = clusterCells([barWith(50, [cluster(100, 5, 0)])]);
    const [r] = cellRects(cells, proj, 7);
    expect(r.h).toBe(7);
  });

  it('drops cells outside the visible range (null projection)', () => {
    const offscreen: GridProjection = {
      timeToX: (ts) => (ts === 50 ? 100 : null),
      priceToY: (p) => 1000 - p,
      barWidth: 10,
    };
    const cells = clusterCells([
      barWith(50, [cluster(100, 5, 0)]),  // on-screen
      barWith(99, [cluster(100, 5, 0)]),  // timeToX → null
    ]);
    const rects = cellRects(cells, offscreen);
    expect(rects).toHaveLength(1);
    expect(rects[0].x).toBe(95); // ts=50 → x 100, minus w/2
  });

  it('tints each rect by its cell colour', () => {
    const cells = clusterCells([
      barWith(50, [cluster(100, 10, 0)]),  // buy-dominant → green-ish
      barWith(51, [cluster(100, 0, 10)]),  // sell-dominant → red-ish
    ]);
    const rects = cellRects(cells, proj);
    expect(rects[0].color).toContain('38,166,154');
    expect(rects[1].color).toContain('239,83,80');
  });

  it('carries the raw buy/sell/delta so the painter can label the cell', () => {
    const cells = clusterCells([barWith(50, [cluster(100, 12, 5, 1)])]);
    const [r] = cellRects(cells, proj);
    expect(r.buy).toBe(12);
    expect(r.sell).toBe(5);
    expect(r.delta).toBe(7);
  });
});

describe('fmtVol', () => {
  it('shows small volumes as plain integers (rounded)', () => {
    expect(fmtVol(0)).toBe('0');
    expect(fmtVol(7)).toBe('7');
    expect(fmtVol(223.69)).toBe('224');
    expect(fmtVol(9999)).toBe('9999');
    expect(fmtVol(-42)).toBe('-42');
  });

  it('abbreviates thousands and millions to keep cells narrow', () => {
    expect(fmtVol(10_000)).toBe('10k');
    expect(fmtVol(12_345)).toBe('12k');
    expect(fmtVol(1_500_000)).toBe('1.5M');
    expect(fmtVol(2_000_000)).toBe('2M');
  });
});
