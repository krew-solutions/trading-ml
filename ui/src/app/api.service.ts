import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map } from 'rxjs';
import { Decimal } from './decimal';

/** Candle is the one internal type kept in `number`: lightweight-charts
 *  takes raw numbers, and indicator math feeds the same array. The
 *  lossy {!Decimal.toNumber} projection is therefore made explicit at
 *  every parse site below — grep for `.toNumber()` to audit every
 *  place the UI rounds Decimal precision off. */
export interface Candle {
  ts: number;
  open: number; high: number; low: number; close: number; volume: number;
}

/** Wire shape matching the backend's {!Candle_view_model.t}:
 *  [ts] as a JSON number, OHLCV as canonical decimal strings
 *  (see {!OCaml.Core.Decimal.to_string}). Parsed via {!Decimal}
 *  at the HTTP boundary for bit-exact round-trip. */
interface WireCandle {
  ts: number;
  open: string;
  high: string;
  low:  string;
  close:  string;
  volume: string;
}

/** Wire-format decimal string → {!Decimal}. Bit-exact parse, no
 *  precision loss; mirrors the OCaml backend's
 *  `Core.Decimal.of_string`. Callers that need a JS `number` (chart
 *  libraries) project explicitly via `.toNumber()` so the lossy step
 *  is visible at the call site. */
const parseDecimal = (s: string): Decimal => Decimal.fromString(s);

const parseCandle = (c: WireCandle): Candle => ({
  ts: c.ts,
  open: parseDecimal(c.open).toNumber(),
  high: parseDecimal(c.high).toNumber(),
  low:  parseDecimal(c.low).toNumber(),
  close:  parseDecimal(c.close).toNumber(),
  volume: parseDecimal(c.volume).toNumber(),
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

/** Discriminated kind of an {!Order} on the read side. Prices are
 *  {!Decimal} because the UI never does chart-feed math on orders —
 *  it only displays them and (rarely) compares — so there's no
 *  reason to round through `number`. */
export type OrderKind =
  | { type: 'MARKET' }
  | { type: 'LIMIT'; price: Decimal }
  | { type: 'STOP';  price: Decimal }
  | { type: 'STOP_LIMIT'; stop_price: Decimal; limit_price: Decimal };

export interface Order {
  client_order_id: string;
  id: string;
  instrument: string;
  side: 'BUY' | 'SELL';
  quantity: Decimal;
  filled: Decimal;
  remaining: Decimal;
  status: string;
  tif: string;
  kind: OrderKind;
  ts: number;
}

/** Wire shape mirroring the backend's {!Order_view_model.t} +
 *  {!Order_kind_view_model.t}: monetary fields are decimal strings.
 *  Optional kind-specific prices are serialised as JSON `null` by
 *  ppx_yojson_conv when the corresponding `option` is `None` (e.g.
 *  `price` for MARKET) — the type matches that 1:1. */
interface WireOrderKind {
  type: 'MARKET' | 'LIMIT' | 'STOP' | 'STOP_LIMIT';
  price: string | null;
  stop_price: string | null;
  limit_price: string | null;
}
interface WireOrder {
  client_order_id: string;
  id: string;
  instrument: string;
  side: 'BUY' | 'SELL';
  quantity: string;
  filled: string;
  remaining: string;
  status: string;
  tif: string;
  kind: WireOrderKind;
  ts: number;
}

/** Throws on a missing required field per kind — strict, since this
 *  is a contract violation: a [LIMIT] order without `price` is
 *  malformed at the source, not something to silently default. */
const requirePrice = (kind: string, field: string, v: string | null): string => {
  if (v === null) throw new Error(`Order kind ${kind}: missing ${field}`);
  return v;
};

const parseKind = (k: WireOrderKind): OrderKind => {
  switch (k.type) {
    case 'MARKET':
      return { type: 'MARKET' };
    case 'LIMIT':
      return { type: 'LIMIT', price: parseDecimal(requirePrice('LIMIT', 'price', k.price)) };
    case 'STOP':
      return { type: 'STOP',  price: parseDecimal(requirePrice('STOP',  'price', k.price)) };
    case 'STOP_LIMIT':
      return {
        type: 'STOP_LIMIT',
        stop_price:  parseDecimal(requirePrice('STOP_LIMIT', 'stop_price',  k.stop_price)),
        limit_price: parseDecimal(requirePrice('STOP_LIMIT', 'limit_price', k.limit_price)),
      };
  }
};

const parseOrder = (o: WireOrder): Order => ({
  client_order_id: o.client_order_id,
  id: o.id,
  instrument: o.instrument,
  side: o.side,
  quantity:  parseDecimal(o.quantity),
  filled:    parseDecimal(o.filled),
  remaining: parseDecimal(o.remaining),
  status: o.status,
  tif: o.tif,
  kind: parseKind(o.kind),
  ts: o.ts,
});

/** Form-input shape: numeric prices/quantities come straight from
 *  `<input type="number">`, which already lives in IEEE 754. We keep
 *  the form contract honest about that and convert to {!Decimal} (and
 *  then to the canonical decimal string) only at the wire boundary —
 *  same discipline as on the server side, where {!Reserve_command}
 *  reads `Decimal.of_string` regardless of how the UI typed it. */
export type PlaceOrderKind =
  | { type: 'MARKET' }
  | { type: 'LIMIT'; price: number }
  | { type: 'STOP';  price: number }
  | { type: 'STOP_LIMIT'; stop_price: number; limit_price: number };

export interface PlaceOrderRequest {
  symbol: string;
  side: 'BUY' | 'SELL';
  quantity: number;
  client_order_id: string;
  kind: PlaceOrderKind;
  tif?: 'DAY' | 'GTC' | 'IOC' | 'FOK';
}

/** number → canonical decimal string for outbound monetary fields.
 *  Goes through {!Decimal} so the server reads us via
 *  `Decimal.of_string`, not the lossy `Decimal.of_float` path —
 *  the wire becomes the authoritative form even on POSTs. */
const toWire = (n: number): string => Decimal.fromNumber(n).toString();

const wirePlaceOrderKind = (k: PlaceOrderKind): WireOrderKind => {
  switch (k.type) {
    case 'MARKET':
      return { type: 'MARKET', price: null, stop_price: null, limit_price: null };
    case 'LIMIT':
      return { type: 'LIMIT', price: toWire(k.price), stop_price: null, limit_price: null };
    case 'STOP':
      return { type: 'STOP',  price: toWire(k.price), stop_price: null, limit_price: null };
    case 'STOP_LIMIT':
      return {
        type: 'STOP_LIMIT',
        price: null,
        stop_price:  toWire(k.stop_price),
        limit_price: toWire(k.limit_price),
      };
  }
};

interface WirePlaceOrderRequest {
  symbol: string;
  side: 'BUY' | 'SELL';
  quantity: string;
  client_order_id: string;
  kind: WireOrderKind;
  tif?: 'DAY' | 'GTC' | 'IOC' | 'FOK';
}

const wirePlaceOrder = (req: PlaceOrderRequest): WirePlaceOrderRequest => ({
  symbol: req.symbol,
  side: req.side,
  quantity: toWire(req.quantity),
  client_order_id: req.client_order_id,
  kind: wirePlaceOrderKind(req.kind),
  ...(req.tif !== undefined ? { tif: req.tif } : {}),
});

export interface BacktestResult {
  num_trades: number;
  /** Domain ratio (e.g. [0.12] for +12%). Float in the OCaml domain
   *  too — not Decimal-derived. */
  total_return: number;
  /** Domain ratio, see {!total_return}. */
  max_drawdown: number;
  final_cash: Decimal;
  realized_pnl: Decimal;
  equity_curve: { ts: number; equity: Decimal }[];
  fills: { ts: number; side: string; quantity: Decimal; price: Decimal;
           fee: Decimal; reason: string }[];
}

/** Wire shape for {!Backtest_result_view_model.t}: ratios stay
 *  float (domain semantics), Decimal-derived fields are strings. */
interface WireBacktestResult {
  num_trades: number;
  total_return: number;   // domain ratio, not Decimal-derived
  max_drawdown: number;   // domain ratio, not Decimal-derived
  final_cash: string;
  realized_pnl: string;
  equity_curve: { ts: number; equity: string }[];
  fills: {
    ts: number; side: string;
    quantity: string; price: string; fee: string;
    reason: string;
  }[];
}

const parseBacktest = (r: WireBacktestResult): BacktestResult => ({
  num_trades: r.num_trades,
  total_return: r.total_return,
  max_drawdown: r.max_drawdown,
  final_cash: parseDecimal(r.final_cash),
  realized_pnl: parseDecimal(r.realized_pnl),
  equity_curve: r.equity_curve.map(p => ({ ts: p.ts, equity: parseDecimal(p.equity) })),
  fills: r.fills.map(f => ({
    ts: f.ts, side: f.side,
    quantity: parseDecimal(f.quantity),
    price: parseDecimal(f.price),
    fee: parseDecimal(f.fee),
    reason: f.reason,
  })),
});

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
    return this.http.post<WireBacktestResult>('/api/backtest', body)
      .pipe(map(parseBacktest));
  }

  orders(): Observable<{ orders: Order[] }> {
    return this.http.get<{ orders: WireOrder[] }>('/api/orders')
      .pipe(map(r => ({ orders: r.orders.map(parseOrder) })));
  }
  placeOrder(req: PlaceOrderRequest): Observable<Order> {
    return this.http.post<WireOrder>('/api/orders', wirePlaceOrder(req))
      .pipe(map(parseOrder));
  }
  cancelOrder(cid: string): Observable<Order> {
    return this.http.delete<WireOrder>(`/api/orders/${encodeURIComponent(cid)}`)
      .pipe(map(parseOrder));
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
