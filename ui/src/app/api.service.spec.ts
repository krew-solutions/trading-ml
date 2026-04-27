import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController, provideHttpClientTesting,
} from '@angular/common/http/testing';
import { Api, type StreamEvent } from './api.service';

describe('Api', () => {
  let api: Api;
  let httpCtrl: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting(), Api],
    });
    api = TestBed.inject(Api);
    httpCtrl = TestBed.inject(HttpTestingController);
  });

  afterEach(() => httpCtrl.verify());

  it('GETs /api/candles with symbol, n and default H1 timeframe', () => {
    api.candles('SBER', 100).subscribe();
    const req = httpCtrl.expectOne(
      '/api/candles?symbol=SBER&n=100&timeframe=H1');
    expect(req.request.method).toBe('GET');
    req.flush({ candles: [] });
  });

  it('GETs /api/candles with an explicit timeframe', () => {
    api.candles('GAZP', 50, 'M15').subscribe();
    httpCtrl
      .expectOne('/api/candles?symbol=GAZP&n=50&timeframe=M15')
      .flush({ candles: [] });
  });

  it('GETs /api/strategies', () => {
    api.strategies().subscribe(spec => expect(spec).toEqual([]));
    httpCtrl.expectOne('/api/strategies').flush([]);
  });

  describe('stream() (EventSource)', () => {
    /** Minimal EventSource stub: tests drive named-channel listeners
     *  ([bar], [order]) plus onerror, and assert that close() happens
     *  on unsubscribe. */
    class StubEventSource {
      static CLOSED = 2;
      url: string;
      readyState = 0;
      onerror: (() => void) | null = null;
      closed = false;
      private listeners: Record<string, ((e: { data: string }) => void)[]> = {};
      constructor(url: string) {
        this.url = url;
        StubEventSource.last = this;
      }
      addEventListener(name: string, fn: (e: { data: string }) => void) {
        (this.listeners[name] ??= []).push(fn);
      }
      removeEventListener(name: string, fn: (e: { data: string }) => void) {
        this.listeners[name] = (this.listeners[name] ?? []).filter(f => f !== fn);
      }
      close() { this.closed = true; this.readyState = 2; }
      emit(name: string, data: unknown) {
        for (const fn of this.listeners[name] ?? []) {
          fn({ data: JSON.stringify(data) });
        }
      }
      static last: StubEventSource | null = null;
    }

    let origES: typeof globalThis.EventSource | undefined;
    beforeEach(() => {
      origES = globalThis.EventSource;
      (globalThis as unknown as { EventSource: unknown }).EventSource =
        StubEventSource;
    });
    afterEach(() => {
      (globalThis as unknown as { EventSource: unknown }).EventSource =
        origES as unknown;
    });

    it('opens /api/stream with the requested bar feed in ?bars=', () => {
      const sub = api.stream('SBER', 'M5').subscribe(() => {});
      expect(StubEventSource.last?.url)
        .toBe('/api/stream?bars=SBER%3AM5');
      sub.unsubscribe();
    });

    it('parses bar-channel messages into typed events', () => {
      const received: StreamEvent[] = [];
      const sub = api.stream('SBER', 'H1').subscribe(ev => received.push(ev));
      StubEventSource.last!.emit('bar', {
        kind: 'seed', symbol: 'SBER', timeframe: 'H1', candles: [],
      });
      StubEventSource.last!.emit('bar', {
        kind: 'updated', symbol: 'SBER', timeframe: 'H1',
        candle: { ts: 1, open: 1, high: 1, low: 1, close: 1, volume: 1 },
      });
      expect(received.map(e => e.kind)).toEqual(['seed', 'updated']);
      sub.unsubscribe();
    });

    it('logs order-channel messages without surfacing them on the bar observable',
      () => {
        const received: StreamEvent[] = [];
        const debug = vi.spyOn(console, 'debug').mockImplementation(() => {});
        const sub = api.stream('SBER', 'H1').subscribe(ev => received.push(ev));
        StubEventSource.last!.emit('order', { kind: 'amount_reserved', payload: {} });
        expect(received).toEqual([]);
        expect(debug).toHaveBeenCalledWith('[sse] order',
          { kind: 'amount_reserved', payload: {} });
        debug.mockRestore();
        sub.unsubscribe();
      });

    it('closes the EventSource on unsubscribe', () => {
      const sub = api.stream('SBER', 'H1').subscribe(() => {});
      sub.unsubscribe();
      expect(StubEventSource.last?.closed).toBe(true);
    });

    it('errors the observable when the EventSource is closed', () => {
      const err = vi.fn();
      api.stream('SBER', 'H1').subscribe({
        next: () => {}, error: err,
      });
      StubEventSource.last!.readyState = StubEventSource.CLOSED;
      StubEventSource.last!.onerror?.();
      expect(err).toHaveBeenCalledOnce();
    });
  });

  it('GETs /api/orders and returns the list', () => {
    const sample = {
      client_order_id: 'cid-1', id: 'cid-1', instrument: 'SBER@MISX',
      side: 'BUY' as const, quantity: 10, filled: 0, remaining: 10,
      status: 'New', tif: 'DAY', kind: { type: 'MARKET' as const }, ts: 0,
    };
    let got: unknown;
    api.orders().subscribe(r => (got = r.orders));
    httpCtrl.expectOne('/api/orders').flush({ orders: [sample] });
    expect(got).toEqual([sample]);
  });

  it('POSTs /api/orders with the place-order body', () => {
    api.placeOrder({
      symbol: 'SBER@MISX', side: 'BUY', quantity: 10,
      client_order_id: 'cid-2', kind: { type: 'MARKET' },
    }).subscribe();
    const req = httpCtrl.expectOne('/api/orders');
    expect(req.request.method).toBe('POST');
    expect(req.request.body.client_order_id).toBe('cid-2');
    req.flush({
      client_order_id: 'cid-2', id: 'cid-2', instrument: 'SBER@MISX',
      side: 'BUY', quantity: 10, filled: 0, remaining: 10,
      status: 'New', tif: 'DAY', kind: { type: 'MARKET' }, ts: 0,
    });
  });

  it('DELETEs /api/orders/:cid on cancel', () => {
    api.cancelOrder('cid-3').subscribe();
    const req = httpCtrl.expectOne('/api/orders/cid-3');
    expect(req.request.method).toBe('DELETE');
    req.flush({
      client_order_id: 'cid-3', id: 'cid-3', instrument: 'SBER@MISX',
      side: 'BUY', quantity: 10, filled: 0, remaining: 0,
      status: 'Cancelled', tif: 'DAY', kind: { type: 'MARKET' }, ts: 0,
    });
  });

  it('POSTs /api/backtest with JSON body', () => {
    api.backtest({
      symbol: 'GAZP', strategy: 'SMA_Crossover',
      params: { fast: 10 }, n: 200,
    }).subscribe();
    const req = httpCtrl.expectOne('/api/backtest');
    expect(req.request.method).toBe('POST');
    expect(req.request.body).toEqual({
      symbol: 'GAZP', strategy: 'SMA_Crossover',
      params: { fast: 10 }, n: 200,
    });
    req.flush({
      num_trades: 0, total_return: 0, max_drawdown: 0,
      final_cash: 0, realized_pnl: 0, equity_curve: [], fills: [],
    });
  });
});
