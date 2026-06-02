/** Footprint domain types for the UI and the *true* Cumulative Volume
 *  Delta derived from them.
 *
 *  Unlike a candle-range proxy, which can only estimate per-bar delta
 *  from the close's position within the range, this CVD is the running
 *  sum of the REAL aggressor-signed delta the order_flow BC measures from
 *  the public tape (ADR 0032). The per-bar figure is a
 *  fact carried on the wire; the *cumulative* sum is a presentation
 *  projection computed here in the consumer, anchored at the start of the
 *  loaded window. */

import { Decimal } from '../decimal';
import {
  applyStyle,
  type IndicatorOverlay, type OverlayStyle,
} from '../indicators/overlay';

/** One price level of a footprint bar, projected into the chart's
 *  number domain: the price and the volume traded there split by
 *  aggressor (the directionless bucket counts toward total but not
 *  delta — ADR 0032). */
export interface FootprintCluster {
  price: number;
  buy: number;
  sell: number;
  indeterminate: number;
}

/** One sealed footprint bar as the chart consumes it: the bar's open
 *  time, its signed delta, and (for the cluster grid) its per-price
 *  clusters. The CVD line needs only (ts, delta); [clusters] is empty
 *  when a caller projects only what the line needs. */
export interface FootprintBar {
  ts: number;
  delta: number;
  clusters: FootprintCluster[];
}

/** Cumulative Volume Delta from measured per-bar deltas: the running sum,
 *  anchored at 0 before the first bar of the window. Order-preserving;
 *  the caller passes bars oldest-first (as /api/footprints returns them). */
export function cvdTrue(bars: FootprintBar[]): number[] {
  const out = new Array<number>(bars.length);
  let sum = 0;
  for (let i = 0; i < bars.length; i++) {
    sum += bars[i].delta;
    out[i] = sum;
  }
  return out;
}

/** Overlay for the true CVD line, drawn in its own secondary pane
 *  ('cvd-true', distinct from the proxy's 'cvd' pane so both can coexist
 *  during the transition). */
export function cvdTrueOverlay(
  bars: FootprintBar[],
  style: OverlayStyle,
): IndicatorOverlay {
  const series = cvdTrue(bars);
  return {
    name: 'CVD (order flow)',
    pane: 'cvd-true',
    lines: [
      {
        label: 'CVD',
        color: style.color,
        ...applyStyle(style),
        points: series.map((v, i) => ({ ts: bars[i].ts, v })),
      },
    ],
  };
}

/** ISO-8601 [open_ts] (the wire form) → unix epoch seconds, matching the
 *  [ts: number] the chart's time scale uses for candles. */
export function parseOpenTs(iso: string): number {
  return Math.floor(Date.parse(iso) / 1000);
}

/** Project a wire footprint DTO's signed [delta] (a decimal string,
 *  ADR 0007) into the chart's [number] domain — the same explicit lossy
 *  step the candle parser makes via Decimal.toNumber(). */
export function parseDelta(delta: string): number {
  return Decimal.fromString(delta).toNumber();
}

/** Project one wire cluster (decimal-string buckets) into the chart's
 *  number domain. */
export function parseCluster(c: {
  price: string;
  buy_volume: string;
  sell_volume: string;
  indeterminate_volume: string;
}): FootprintCluster {
  return {
    price: Decimal.fromString(c.price).toNumber(),
    buy: Decimal.fromString(c.buy_volume).toNumber(),
    sell: Decimal.fromString(c.sell_volume).toNumber(),
    indeterminate: Decimal.fromString(c.indeterminate_volume).toNumber(),
  };
}

// ---------------------------------------------------------------------------
// Cluster-grid geometry — pure, coordinate-free core (phase 6a).
//
// The grid is a heatmap of per-price buy/sell volume drawn over the price
// chart. lightweight-charts cannot draw such a grid, so a custom canvas
// overlay (phase 6b) paints it; everything that can be decided without a
// canvas — which cells exist, their colour, their value→intensity scale —
// lives here as pure functions so it is unit-testable.
// ---------------------------------------------------------------------------

/** A single grid cell ready to be placed by the painter: which bar and
 *  price level it belongs to, the dominant-aggressor colour, and a [0,1]
 *  intensity (its total volume relative to the grid's busiest cell). */
export interface ClusterCell {
  ts: number;
  price: number;
  /** buy + sell + indeterminate at this level. */
  total: number;
  /** buy − sell (directionless excluded). */
  delta: number;
  /** ask-aggressor (lifted-the-offer) volume at this level. */
  buy: number;
  /** bid-aggressor (hit-the-bid) volume at this level. */
  sell: number;
  /** [0, 1]: total / max-total across all cells in the grid. */
  intensity: number;
}

/** Flatten footprint bars into grid cells with a normalised intensity.
 *  Intensity is relative to the single busiest cell in the window, so the
 *  heatmap self-scales to whatever is on screen; an all-empty grid yields
 *  no cells. Pure and order-preserving. */
export function clusterCells(bars: FootprintBar[]): ClusterCell[] {
  let maxTotal = 0;
  for (const b of bars) {
    for (const c of b.clusters) {
      const total = c.buy + c.sell + c.indeterminate;
      if (total > maxTotal) maxTotal = total;
    }
  }
  if (maxTotal <= 0) return [];
  const cells: ClusterCell[] = [];
  for (const b of bars) {
    for (const c of b.clusters) {
      const total = c.buy + c.sell + c.indeterminate;
      if (total <= 0) continue;
      cells.push({
        ts: b.ts,
        price: c.price,
        total,
        delta: c.buy - c.sell,
        buy: c.buy,
        sell: c.sell,
        intensity: total / maxTotal,
      });
    }
  }
  return cells;
}

/** Heatmap colour for a cell: green when buyers dominate the level, red
 *  when sellers do, grey when balanced or directionless; opacity tracks
 *  [intensity] so heavy levels read darker. Returns an `rgba(...)` string.
 *  Pure — no canvas, fully testable. */
export function cellColor(cell: ClusterCell): string {
  // Floor the alpha so even light cells stay visible; cap below 1 so the
  // candles underneath remain legible through the busiest cells.
  const alpha = 0.15 + 0.65 * Math.min(1, Math.max(0, cell.intensity));
  const rgb =
    cell.delta > 0 ? '38,166,154'   // buy-dominant  (teal/green)
    : cell.delta < 0 ? '239,83,80'  // sell-dominant (red)
    : '120,120,120';                // balanced / directionless
  return `rgba(${rgb},${alpha.toFixed(3)})`;
}

/** A cell placed in pixel space, ready to fill. [x],[y] is the top-left
 *  corner; [w],[h] the size; [color] the heatmap fill; [buy]/[sell]/[delta]
 *  the per-level volumes the painter prints inside the cell when it is
 *  large enough. */
export interface CellRect {
  x: number;
  y: number;
  w: number;
  h: number;
  color: string;
  buy: number;
  sell: number;
  delta: number;
}

/** Compact volume label for an in-cell footprint number: a plain integer
 *  up to 9999, then ["12k"], then ["3.4M"]. Keeps cells legible without
 *  the digits overflowing the column. Pure. */
export function fmtVol(v: number): string {
  const r = Math.round(v);
  const a = Math.abs(r);
  if (a >= 1_000_000) return (r / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M';
  if (a >= 10_000) return Math.round(r / 1000) + 'k';
  return String(r);
}

/** Chart→pixel projections the painter injects. Each returns null when
 *  the value falls outside the visible range (lightweight-charts'
 *  contract), in which case the cell is skipped. */
export interface GridProjection {
  /** Bar open time → x pixel of the bar's centre. */
  timeToX: (ts: number) => number | null;
  /** Price → y pixel. */
  priceToY: (price: number) => number | null;
  /** Pixel width of one bar (lightweight-charts' barSpacing). */
  barWidth: number;
}

/** Map grid cells to pixel rectangles using the injected projections —
 *  the load-bearing geometry of the cluster overlay, kept pure (no
 *  canvas, no chart object) so it is unit-testable.
 *
 *  Each cell is a [barWidth]-wide column centred on its bar, one price
 *  level tall. The level height is inferred from the nearest price gap on
 *  the same bar (the tick grid is uneven), falling back to [defaultPriceH]
 *  pixels for a lone level. Cells outside the visible range (null
 *  projection) are dropped. */
export function cellRects(
  cells: ClusterCell[],
  proj: GridProjection,
  defaultPriceH = 6,
): CellRect[] {
  // Per-bar sorted price ladder, to size each level by its neighbour gap.
  const pricesByTs = new Map<number, number[]>();
  for (const c of cells) {
    const arr = pricesByTs.get(c.ts) ?? [];
    arr.push(c.price);
    pricesByTs.set(c.ts, arr);
  }
  for (const arr of pricesByTs.values()) arr.sort((a, b) => a - b);

  const rects: CellRect[] = [];
  for (const cell of cells) {
    const xc = proj.timeToX(cell.ts);
    const yc = proj.priceToY(cell.price);
    if (xc === null || yc === null) continue;

    // Height: distance in pixels to the adjacent price level on this bar.
    const ladder = pricesByTs.get(cell.ts)!;
    const i = ladder.indexOf(cell.price);
    const neighbour =
      i + 1 < ladder.length ? ladder[i + 1]
      : i - 1 >= 0 ? ladder[i - 1]
      : null;
    let h = defaultPriceH;
    if (neighbour !== null) {
      const yn = proj.priceToY(neighbour);
      if (yn !== null) h = Math.max(1, Math.abs(yn - yc));
    }

    const w = Math.max(1, proj.barWidth);
    rects.push({
      x: xc - w / 2,
      y: yc - h / 2,
      w,
      h,
      color: cellColor(cell),
      buy: cell.buy,
      sell: cell.sell,
      delta: cell.delta,
    });
  }
  return rects;
}
