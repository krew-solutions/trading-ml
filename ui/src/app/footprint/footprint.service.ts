import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import type { Timeframe } from '../api.service';
import { type FootprintBar, parseCluster, parseDelta, parseOpenTs } from './footprint';
import {
  readT as readFootprint,
  type T as WireFootprint,
} from './generated/footprint_completed_integration_event';

/** Project a validated wire footprint DTO into the chart's minimal
 *  (ts, delta) bar. [readFootprint] (atdts-generated) validates the JSON
 *  shape at the boundary and throws on a contract violation, so the
 *  projection below sees only well-formed input. */
const toBar = (w: WireFootprint): FootprintBar => ({
  ts: parseOpenTs(w.open_ts),
  delta: parseDelta(w.delta),
  clusters: w.clusters.map(parseCluster),
});

/** A live footprint seal, with the feed key the server echoes so a
 *  multi-feed consumer can route; today one feed per stream. */
export interface FootprintSeal {
  symbol: string;
  /** Boundary token: a timeframe ("M5") or a volume cap ("VOL:1000"). */
  token: string;
  bar: FootprintBar;
}

@Injectable({ providedIn: 'root' })
export class FootprintApi {
  private http = inject(HttpClient);

  /** Recent sealed footprints for [(symbol, timeframe)], oldest-first —
   *  the seed the CVD line accumulates before the live stream takes over.
   *  Each element is validated through the generated reader. */
  recent(symbol: string, timeframe: Timeframe, n: number): Observable<FootprintBar[]> {
    const q = new URLSearchParams({ symbol, timeframe, n: String(n) });
    return this.http
      .get<{ footprints: unknown[] }>(`/api/footprints?${q}`)
      .pipe(map(r => r.footprints.map(x => toBar(readFootprint(x)))));
  }

  /** Live footprint seals for [(symbol, timeframe)] over the SSE
   *  [footprint] channel. The server frames each as
   *  `{ kind: "footprint", payload: <DTO> }`; the payload is validated
   *  through the generated reader, and the feed token is taken from the
   *  DTO's own [timeframe] field. */
  stream(symbol: string, timeframe: Timeframe): Observable<FootprintSeal> {
    const q = new URLSearchParams({ footprints: `${symbol}:${timeframe}` });
    return new Observable<FootprintSeal>(subscriber => {
      const es = new EventSource(`/api/stream?${q}`);
      const onFootprint = (ev: MessageEvent) => {
        try {
          const env = JSON.parse(ev.data) as { kind: string; payload: unknown };
          const w = readFootprint(env.payload);
          subscriber.next({ symbol, token: w.timeframe, bar: toBar(w) });
        } catch (e) {
          subscriber.error(e);
        }
      };
      es.addEventListener('footprint', onFootprint);
      es.onerror = () => {
        if (es.readyState === EventSource.CLOSED) {
          subscriber.error(new Error('SSE footprint stream closed'));
        }
      };
      return () => {
        es.removeEventListener('footprint', onFootprint);
        es.close();
      };
    });
  }
}
