import { describe, it, expect } from 'vitest';
import {
  readT as readFootprint,
} from './generated/footprint_completed_integration_event';
import { parseCluster, parseDelta, parseOpenTs } from './footprint';

/** A footprint payload in exactly the shape mock-server.mjs emits (and
 *  the OCaml backend's footprint_completed_integration_event): nested
 *  instrument view model, decimal-string amounts, ISO-8601 open_ts,
 *  per-price clusters. Kept here as the contract the mock must satisfy —
 *  if the mock shape drifts, this gate (run through the SAME generated
 *  reader the UI uses) catches it. */
const mockPayload = {
  instrument: { ticker: 'SBER', venue: 'MISX', board: 'TQBR' },
  timeframe: 'M5',
  open_ts: '2024-01-01T00:00:00.000Z',
  open_price: '109.94',
  high: '111.06',
  low: '109.54',
  close: '110.51',
  volume: '1202',
  delta: '250',
  poc_price: '109.54',
  clusters: [
    { price: '109.54', buy_volume: '223.69', sell_volume: '97.36', indeterminate_volume: '7.01' },
    { price: '109.92', buy_volume: '146.85', sell_volume: '87.35', indeterminate_volume: '0' },
  ],
};

describe('mock footprint contract', () => {
  it('passes the atdts-generated reader the UI validates with', () => {
    // readFootprint throws on any missing/mistyped field; reaching the
    // assertions means the mock shape is contract-valid.
    const w = readFootprint(mockPayload);
    expect(w.timeframe).toBe('M5');
    expect(w.clusters).toHaveLength(2);
    expect(w.instrument.board).toBe('TQBR');
  });

  it('projects through the same helpers the service uses', () => {
    const w = readFootprint(mockPayload);
    expect(parseOpenTs(w.open_ts)).toBe(Date.UTC(2024, 0, 1) / 1000);
    expect(parseDelta(w.delta)).toBe(250);
    const c0 = parseCluster(w.clusters[0]);
    expect(c0).toEqual({ price: 109.54, buy: 223.69, sell: 97.36, indeterminate: 7.01 });
  });

  it('rejects a payload missing a required field (reader is a real gate)', () => {
    const broken = { ...mockPayload };
    delete (broken as Record<string, unknown>)['delta'];
    expect(() => readFootprint(broken)).toThrow();
  });
});
