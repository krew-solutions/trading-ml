import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

export interface Candle {
  ts: number;
  open: number; high: number; low: number; close: number; volume: number;
}

export interface IndicatorSpec {
  name: string;
  params: { name: string; type: string; default: unknown }[];
}

export interface StrategySpec extends IndicatorSpec {}

export type Timeframe =
  | 'M1' | 'M5' | 'M15' | 'M30'
  | 'H1' | 'H4'
  | 'D1' | 'W1' | 'MN1';

export const TIMEFRAMES: Timeframe[] = [
  'M1', 'M5', 'M15', 'M30', 'H1', 'H4', 'D1', 'W1', 'MN1',
];

/** Market Identifier Code (ISO 10383). Finam's new API expects symbols
 *  in [TICKER@MIC] form. Short static list for now — if Finam exposes a
 *  directory endpoint (e.g. /v1/exchanges), we can fetch dynamically. */
/** Static fallback — used before /api/exchanges responds, or when the
 *  endpoint isn't reachable. Finam returns MIC codes as plain strings
 *  so we keep the type [string] in the runtime wire shape and the
 *  curated literal type for the fallback set. */
export type Mic = string;

export const MICS_FALLBACK: Mic[] = ['MISX', 'XSPB'];

export interface Exchange {
  mic: string;
  name: string;
}

export interface BacktestResult {
  num_trades: number;
  total_return: number;
  max_drawdown: number;
  final_cash: number;
  realized_pnl: number;
  equity_curve: { ts: number; equity: number }[];
  fills: { ts: number; side: string; quantity: number; price: number;
           fee: number; reason: string }[];
}

@Injectable({ providedIn: 'root' })
export class Api {
  private http = inject(HttpClient);

  indicators(): Observable<IndicatorSpec[]> {
    return this.http.get<IndicatorSpec[]>('/api/indicators');
  }
  strategies(): Observable<StrategySpec[]> {
    return this.http.get<StrategySpec[]>('/api/strategies');
  }
  exchanges(): Observable<{ exchanges: Exchange[] }> {
    return this.http.get<{ exchanges: Exchange[] }>('/api/exchanges');
  }
  candles(symbol: string, n: number, timeframe: Timeframe = 'H1')
    : Observable<{ candles: Candle[] }> {
    const q = new URLSearchParams({
      symbol, n: String(n), timeframe,
    });
    return this.http.get<{ candles: Candle[] }>(`/api/candles?${q}`);
  }
  backtest(body: {
    symbol: string; strategy: string; timeframe?: Timeframe;
    params: Record<string, number | boolean>; n: number;
  }): Observable<BacktestResult> {
    return this.http.post<BacktestResult>('/api/backtest', body);
  }

  /** Opens a Server-Sent Events connection. Returns an Observable that
   *  emits parsed stream events and ties into the given [AbortSignal] for
   *  cleanup (closing the EventSource when the consumer unsubscribes). */
  stream(symbol: string, timeframe: Timeframe): Observable<StreamEvent> {
    const q = new URLSearchParams({ symbol, timeframe });
    return new Observable<StreamEvent>(subscriber => {
      const es = new EventSource(`/api/stream?${q}`);
      es.onmessage = (ev) => {
        try { subscriber.next(JSON.parse(ev.data)); }
        catch (e) { subscriber.error(e); }
      };
      es.onerror = () => {
        // EventSource auto-reconnects on transient errors; we only
        // propagate when the browser itself marks the connection closed.
        if (es.readyState === EventSource.CLOSED) {
          subscriber.error(new Error('SSE stream closed'));
        }
      };
      return () => es.close();
    });
  }
}

export type StreamEvent =
  | { kind: 'seed';        candles: Candle[] }
  | { kind: 'bar_update';  candle: Candle }
  | { kind: 'bar_closed';  candle: Candle };
