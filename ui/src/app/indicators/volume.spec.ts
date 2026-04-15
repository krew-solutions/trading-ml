import { describe, it, expect } from 'vitest';
import { volume, volumeOverlay } from './volume';
import type { OverlayBar } from './overlay';

const bar = (
  ts: number, open: number, high: number, low: number, close: number, v: number,
): OverlayBar => ({ ts, open, high, low, close, volume: v });

describe('volume', () => {
  it('lifts per-bar volumes in order', () => {
    const cs = [bar(0, 1, 2, 0, 1, 10), bar(1, 1, 2, 0, 1, 20)];
    expect(volume(cs)).toEqual([10, 20]);
  });
});

describe('volumeOverlay', () => {
  it('is a single histogram series on the volume pane', () => {
    const cs = [bar(0, 1, 2, 0, 1, 100)];
    const o = volumeOverlay(cs, {}, { color: '#ffffff' });
    expect(o.pane).toBe('volume');
    expect(o.lines).toHaveLength(1);
    expect(o.lines[0].kind).toBe('histogram');
  });

  it('tags bullish bars green and bearish bars red', () => {
    const up   = bar(0, 10, 12, 9, 11, 100);   // close > open
    const down = bar(1, 11, 11, 8,  9, 100);   // close < open
    const pts = volumeOverlay([up, down], {}, { color: '#000' }).lines[0].points;
    expect(pts[0].color).toBe('#26a69a');
    expect(pts[1].color).toBe('#ef5350');
  });

  it('emits one histogram point per bar with matching ts and volume', () => {
    const cs = [bar(100, 1, 2, 0, 1, 7), bar(200, 1, 2, 0, 1, 42)];
    const pts = volumeOverlay(cs, {}, { color: '#000' }).lines[0].points;
    expect(pts.map(p => p.ts)).toEqual([100, 200]);
    expect(pts.map(p => p.v)).toEqual([7, 42]);
  });
});
