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
    /** Minimal EventSource stub: lets tests drive onmessage / onerror
     *  and assert that close() happens on unsubscribe. */
    class StubEventSource {
      static CLOSED = 2;
      url: string;
      readyState = 0;
      onmessage: ((e: { data: string }) => void) | null = null;
      onerror: (() => void) | null = null;
      closed = false;
      constructor(url: string) {
        this.url = url;
        StubEventSource.last = this;
      }
      close() { this.closed = true; this.readyState = 2; }
      emit(data: unknown) {
        this.onmessage?.({ data: JSON.stringify(data) });
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

    it('opens /api/stream with symbol and timeframe', () => {
      const sub = api.stream('SBER', 'M5').subscribe(() => {});
      expect(StubEventSource.last?.url)
        .toBe('/api/stream?symbol=SBER&timeframe=M5');
      sub.unsubscribe();
    });

    it('parses JSON messages into typed events', () => {
      const received: StreamEvent[] = [];
      const sub = api.stream('SBER', 'H1').subscribe(ev => received.push(ev));
      StubEventSource.last!.emit({ kind: 'seed', candles: [] });
      StubEventSource.last!.emit({ kind: 'bar_update', candle: {
        ts: 1, open: 1, high: 1, low: 1, close: 1, volume: 1 } });
      expect(received.map(e => e.kind)).toEqual(['seed', 'bar_update']);
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
