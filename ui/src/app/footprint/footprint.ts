/** Footprint domain types for the UI and the *true* Cumulative Volume
 *  Delta derived from them.
 *
 *  Unlike the candle-range CVD proxy (indicators/cvd.ts), which estimates
 *  per-bar delta from the close's position within the range, this CVD is
 *  the running sum of the REAL aggressor-signed delta the order_flow BC
 *  measures from the public tape (ADR 0032). The per-bar figure is a
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
