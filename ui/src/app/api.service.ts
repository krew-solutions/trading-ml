import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map } from 'rxjs';

/** Internal UI shape — all numeric. Chart libraries and indicator
 *  math work with [number], never strings. */
export interface Candle {
  ts: number;
  open: number; high: number; low: number; close: number; volume: number;
}

/** Wire shape matching the backend's {!Candle_json.yojson_of_t}:
 *  [ts] as a JSON number, OHLCV as JSON strings (canonical Decimal
 *  encoding). Parsed to {!Candle} at the HTTP boundary. */
interface WireCandle {
  ts: number;
  open: string | number;
  high: string | number;
  low:  string | number;
  close:  string | number;
  volume: string | number;
}

const toNum = (v: string | number): number =>
  typeof v === 'number' ? v : parseFloat(v);

const parseCandle = (c: WireCandle): Candle => ({
  ts: c.ts,
  open: toNum(c.open),
  high: toNum(c.high),
  low:  toNum(c.low),
  close:  toNum(c.close),
  volume: toNum(c.volume),
});

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

/** Market Identifier Code (ISO 10383) — identifies a trading venue.
 *  The backend expects a fully-qualified instrument as
 *  [TICKER@MIC[/BOARD]] in the [symbol] query / body field. */
export type Mic = string;

/** Display labels for known venues. Backend only ships MIC codes;
 *  human-readable names live here. Unknown MICs render as the raw
 *  code via {@link micLabel}. */
export const MIC_LABELS: Record<Mic, string> = {
  MISX: 'MOEX',
  IEXG: 'SPB Exchange',
  XNYS: 'NYSE',
  XNGS: 'Nasdaq',
};

export const micLabel = (mic: Mic): string => MIC_LABELS[mic] ?? mic;

export const MICS_FALLBACK: Mic[] = ['MISX', 'IEXG'];

/** QUIK-style trading mode within a venue (e.g. [TQBR], [SMAL],
 *  [SPBFUT]). Optional in the qualified symbol — when omitted, the
 *  Finam adapter routes to the venue's primary board, the BCS adapter
 *  uses its configured default. */
export type Board = string;

export interface Order {
  client_order_id: string;
  id: string;
  instrument: string;
  side: 'BUY' | 'SELL';
  quantity: number;
  filled: number;
  remaining: number;
  status: string;
  tif: string;
  kind: { type: 'MARKET' }
      | { type: 'LIMIT'; price: number }
      | { type: 'STOP';  price: number }
      | { type: 'STOP_LIMIT'; stop_price: number; limit_price: number };
  ts: number;
}

export interface PlaceOrderRequest {
  symbol: string;
  side: 'BUY' | 'SELL';
  quantity: number;
  client_order_id: string;
  kind: Order['kind'];
  tif?: 'DAY' | 'GTC' | 'IOC' | 'FOK';
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
  exchanges(): Observable<{ exchanges: Mic[] }> {
    return this.http.get<{ exchanges: Mic[] }>('/api/exchanges');
  }
  candles(symbol: string, n: number, timeframe: Timeframe = 'H1')
    : Observable<{ candles: Candle[] }> {
    const q = new URLSearchParams({
      symbol, n: String(n), timeframe,
    });
    return this.http.get<{ candles: WireCandle[] }>(`/api/candles?${q}`)
      .pipe(map(r => ({ candles: r.candles.map(parseCandle) })));
  }
  backtest(body: {
    symbol: string; strategy: string; timeframe?: Timeframe;
    /** Param values by name. The allowed JSON types mirror
     *  [Strategies.Registry.param]: int/float become [number],
     *  bool becomes [boolean], and string (e.g. GBT's
     *  [model_path]) becomes [string]. */
    params: Record<string, number | boolean | string>;
    n: number;
  }): Observable<BacktestResult> {
    return this.http.post<BacktestResult>('/api/backtest', body);
  }

  orders(): Observable<{ orders: Order[] }> {
    return this.http.get<{ orders: Order[] }>('/api/orders');
  }
  placeOrder(req: PlaceOrderRequest): Observable<Order> {
    return this.http.post<Order>('/api/orders', req);
  }
  cancelOrder(cid: string): Observable<Order> {
    return this.http.delete<Order>(`/api/orders/${encodeURIComponent(cid)}`);
  }

  /** Opens a Server-Sent Events connection for the given bar feed.
   *  The server multiplexes named channels (`event: bar`, `event: order`)
   *  on a single connection; this method exposes the bar channel,
   *  pre-filtered to the requested [(symbol, timeframe)] feed.
   *
   *  Order events ride the same connection; for now they are logged
   *  by the underlying handler — when the publisher is wired, callers
   *  will get a separate observable for them. */
  stream(symbol: string, timeframe: Timeframe): Observable<StreamEvent> {
    const q = new URLSearchParams({ bars: `${symbol}:${timeframe}` });
    return new Observable<StreamEvent>(subscriber => {
      const es = new EventSource(`/api/stream?${q}`);
      const onBar = (ev: MessageEvent) => {
        try { subscriber.next(parseStreamEvent(JSON.parse(ev.data))); }
        catch (e) { subscriber.error(e); }
      };
      const onOrder = (ev: MessageEvent) => {
        // Placeholder until the order publisher is wired end-to-end:
        // log the envelope so the channel is observable in dev.
        try { console.debug('[sse] order', JSON.parse(ev.data)); }
        catch { /* ignore parse errors on the stub channel */ }
      };
      es.addEventListener('bar', onBar);
      es.addEventListener('order', onOrder);
      es.onerror = () => {
        // EventSource auto-reconnects on transient errors; we only
        // propagate when the browser itself marks the connection closed.
        if (es.readyState === EventSource.CLOSED) {
          subscriber.error(new Error('SSE stream closed'));
        }
      };
      return () => {
        es.removeEventListener('bar', onBar);
        es.removeEventListener('order', onOrder);
        es.close();
      };
    });
  }
}

export type StreamEvent =
  | { kind: 'seed';     symbol: string; timeframe: Timeframe; candles: Candle[] }
  | { kind: 'updated';  symbol: string; timeframe: Timeframe; candle: Candle }
  | { kind: 'closed';   symbol: string; timeframe: Timeframe; candle: Candle };

type WireStreamEvent =
  | { kind: 'seed';     symbol: string; timeframe: Timeframe; candles: WireCandle[] }
  | { kind: 'updated';  symbol: string; timeframe: Timeframe; candle: WireCandle }
  | { kind: 'closed';   symbol: string; timeframe: Timeframe; candle: WireCandle };

const parseStreamEvent = (e: WireStreamEvent): StreamEvent => {
  switch (e.kind) {
    case 'seed':
      return {
        kind: 'seed', symbol: e.symbol, timeframe: e.timeframe,
        candles: e.candles.map(parseCandle),
      };
    case 'updated':
      return {
        kind: 'updated', symbol: e.symbol, timeframe: e.timeframe,
        candle: parseCandle(e.candle),
      };
    case 'closed':
      return {
        kind: 'closed', symbol: e.symbol, timeframe: e.timeframe,
        candle: parseCandle(e.candle),
      };
  }
};
