import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Component, provideZonelessChangeDetection, input } from '@angular/core';
import { TestBed, ComponentFixture } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import {
  HttpTestingController, provideHttpClientTesting,
} from '@angular/common/http/testing';
import { AppComponent } from './app.component';
import { ChartComponent } from './chart.component';
import type { IndicatorOverlay } from './indicators';
import { Candle } from './api.service';

@Component({
  selector: 'app-chart',
  standalone: true,
  template: '',
})
class ChartStubComponent {
  readonly candles = input<Candle[]>([]);
  readonly overlays = input<IndicatorOverlay[]>([]);
}

describe('AppComponent', () => {
  let fixture: ComponentFixture<AppComponent>;
  let httpCtrl: HttpTestingController;

  const indicatorsCatalog = [
    { name: 'SMA', params: [{ name: 'period', type: 'int', default: 20 }] },
    { name: 'EMA', params: [{ name: 'period', type: 'int', default: 20 }] },
    { name: 'BollingerBands', params: [
      { name: 'period', type: 'int', default: 20 },
      { name: 'k', type: 'float', default: 2 },
    ]},
  ];

  const strategies = [
    { name: 'SMA_Crossover', params: [] },
    { name: 'RSI_MeanReversion', params: [] },
  ];

  const candlesFor = (n: number): Candle[] =>
    Array.from({ length: n }, (_, i) => ({
      ts: 1_700_000_000 + i * 60,
      open: 100 + i * 0.1, high: 101 + i * 0.1,
      low: 99 + i * 0.1, close: 100 + i * 0.1, volume: 1000,
    }));

  beforeEach(async () => {
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({
      imports: [AppComponent],
      providers: [
        provideZonelessChangeDetection(),
        provideHttpClient(),
        provideHttpClientTesting(),
      ],
    });
    TestBed.overrideComponent(AppComponent, {
      remove: { imports: [ChartComponent] },
      add: { imports: [ChartStubComponent] },
    });

    fixture = TestBed.createComponent(AppComponent);
    httpCtrl = TestBed.inject(HttpTestingController);

    fixture.detectChanges();
    httpCtrl.expectOne('/api/strategies').flush(strategies);
    httpCtrl.expectOne('/api/indicators').flush(indicatorsCatalog);
    httpCtrl.expectOne('/api/candles?symbol=SBER&n=500&timeframe=H1').flush({
      candles: candlesFor(60),
    });
    await fixture.whenStable();
  });

  afterEach(() => httpCtrl.verify());

  it('initialises the strategy selector from the catalog', () => {
    expect(fixture.componentInstance.strategyName()).toBe('SMA_Crossover');
  });

  it('seeds two default slots (SMA & EMA) from the catalog', () => {
    const slots = fixture.componentInstance.slots();
    expect(slots.map(s => s.specName)).toEqual(['SMA', 'EMA']);
    expect(slots[0].params['period']).toBe(20);
    expect(slots[1].params['period']).toBe(50);
    expect(slots.every(s => s.visible)).toBe(true);
  });

  it('allows adding another slot of the same spec (SMA twice)', async () => {
    const cmp = fixture.componentInstance;
    cmp.pickedSpecName = 'SMA';
    cmp.addSlot();
    await fixture.whenStable();
    const smas = cmp.slots().filter(s => s.specName === 'SMA');
    expect(smas.length).toBe(2);
  });

  it('patches style independently per slot', async () => {
    const cmp = fixture.componentInstance;
    const [sma, ema] = cmp.slots();
    cmp.patchStyle(sma.id, { color: '#ff0000', lineWidth: 3 });
    cmp.patchStyle(ema.id, { lineStyle: 'dashed', opacity: 0.5 });
    await fixture.whenStable();
    const s = cmp.slots();
    expect(s[0].style.color).toBe('#ff0000');
    expect(s[0].style.lineWidth).toBe(3);
    expect(s[1].style.lineStyle).toBe('dashed');
    expect(s[1].style.opacity).toBe(0.5);
  });

  it('removes a slot by id', async () => {
    const cmp = fixture.componentInstance;
    const [first] = cmp.slots();
    cmp.removeSlot(first.id);
    await fixture.whenStable();
    expect(cmp.slots().some(s => s.id === first.id)).toBe(false);
  });

  it('recomputes overlays when a slot is hidden', async () => {
    const cmp = fixture.componentInstance;
    expect(cmp.overlays().length).toBe(2);
    cmp.patchSlot(cmp.slots()[0].id, { visible: false });
    await fixture.whenStable();
    expect(cmp.overlays().length).toBe(1);
  });

  it('reloads candles when the timeframe changes', async () => {
    fixture.componentInstance.timeframe.set('M15');
    await fixture.whenStable();
    httpCtrl.expectOne('/api/candles?symbol=SBER&n=500&timeframe=M15').flush({
      candles: candlesFor(40),
    });
    await fixture.whenStable();
    expect(fixture.componentInstance.candles().length).toBe(40);
  });

  it('reloads candles when the symbol changes', async () => {
    fixture.componentInstance.symbol.set('GAZP');
    await fixture.whenStable();
    httpCtrl.expectOne('/api/candles?symbol=GAZP&n=500&timeframe=H1').flush({
      candles: candlesFor(30),
    });
    await fixture.whenStable();
    expect(fixture.componentInstance.candles().length).toBe(30);
  });

  describe('applyStreamEvent', () => {
    const sampleCandle = (ts: number, close: number): Candle => ({
      ts, open: close, high: close + 1, low: close - 1, close, volume: 1,
    });

    it('replaces the whole array on seed', () => {
      const cmp = fixture.componentInstance;
      const seed = [sampleCandle(1, 100), sampleCandle(2, 101)];
      cmp.applyStreamEvent({ kind: 'seed', candles: seed });
      expect(cmp.candles()).toEqual(seed);
    });

    it('patches trailing bar on bar_update when ts matches', () => {
      const cmp = fixture.componentInstance;
      cmp.candles.set([sampleCandle(1, 100), sampleCandle(2, 101)]);
      const patched = sampleCandle(2, 105);
      cmp.applyStreamEvent({ kind: 'bar_update', candle: patched });
      expect(cmp.candles().at(-1)?.close).toBe(105);
      expect(cmp.candles().length).toBe(2);
    });

    it('appends on bar_closed with a newer ts', () => {
      const cmp = fixture.componentInstance;
      cmp.candles.set([sampleCandle(1, 100)]);
      cmp.applyStreamEvent({
        kind: 'bar_closed', candle: sampleCandle(2, 101),
      });
      expect(cmp.candles().map(c => c.ts)).toEqual([1, 2]);
    });

    it('trims to [n] when appending past the window', () => {
      const cmp = fixture.componentInstance;
      cmp.n.set(3);
      cmp.candles.set([
        sampleCandle(1, 10), sampleCandle(2, 11), sampleCandle(3, 12),
      ]);
      cmp.applyStreamEvent({
        kind: 'bar_closed', candle: sampleCandle(4, 13),
      });
      expect(cmp.candles().map(c => c.ts)).toEqual([2, 3, 4]);
    });
  });

  it('stores the backtest result on success', async () => {
    fixture.componentInstance.runBacktest();
    const req = httpCtrl.expectOne('/api/backtest');
    req.flush({
      num_trades: 3, total_return: 0.05, max_drawdown: 0.02,
      final_cash: 1_050_000, realized_pnl: 50_000,
      equity_curve: [], fills: [],
    });
    await fixture.whenStable();
    expect(fixture.componentInstance.result()?.num_trades).toBe(3);
  });
});
