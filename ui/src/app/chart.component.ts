import {
  AfterViewInit, ChangeDetectionStrategy, Component, ElementRef,
  OnDestroy, effect, input, viewChild,
} from '@angular/core';
import {
  createChart, IChartApi, ISeriesApi, LineData, CandlestickData,
  CandlestickSeries, LineSeries, Time,
} from 'lightweight-charts';
import { Candle } from './api.service';
import { type IndicatorOverlay, PRICE_PANE } from './indicators';
export type { IndicatorOverlay };

@Component({
  selector: 'app-chart',
  standalone: true,
  template: `<div #host class="chart-host"></div>`,
  styles: [`.chart-host { width: 100%; height: 720px; }`],
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class ChartComponent implements AfterViewInit, OnDestroy {
  readonly host = viewChild.required<ElementRef<HTMLDivElement>>('host');
  readonly candles = input<Candle[]>([]);
  readonly overlays = input<IndicatorOverlay[]>([]);

  private chart?: IChartApi;
  private candleSeries?: ISeriesApi<'Candlestick'>;
  private overlaySeries: ISeriesApi<'Line'>[] = [];

  constructor() {
    effect(() => {
      const cs = this.candles();
      const ov = this.overlays();
      if (this.chart && this.candleSeries) this.render(cs, ov);
    });
  }

  ngAfterViewInit(): void {
    this.chart = createChart(this.host().nativeElement, {
      layout: { background: { color: '#0f1115' }, textColor: '#d8dae0' },
      grid: {
        vertLines: { color: '#1a1d24' },
        horzLines: { color: '#1a1d24' },
      },
      timeScale: { timeVisible: true, borderColor: '#2a2e38' },
    });
    this.candleSeries = this.chart.addSeries(CandlestickSeries, {
      upColor: '#26a69a', downColor: '#ef5350',
      borderVisible: false,
      wickUpColor: '#26a69a', wickDownColor: '#ef5350',
    });
    this.render(this.candles(), this.overlays());
  }

  ngOnDestroy(): void {
    this.chart?.remove();
  }

  /** Recreates all overlay series and the secondary panes they require.
   *  Secondary panes are keyed by [overlay.pane]; two overlays sharing a
   *  key are stacked in the same pane, which is what MACD/Signal/Hist and
   *  Stochastic %K/%D rely on. */
  private render(candles: Candle[], overlays: IndicatorOverlay[]): void {
    if (!this.chart || !this.candleSeries) return;

    const bars: CandlestickData[] = candles.map(c => ({
      time: Math.floor(c.ts) as Time,
      open: c.open, high: c.high, low: c.low, close: c.close,
    }));
    this.candleSeries.setData(bars);

    // Tear down previous overlay series. Removing the last series from a
    // pane auto-collapses that pane in lightweight-charts v5.
    for (const s of this.overlaySeries) this.chart.removeSeries(s);
    this.overlaySeries = [];

    // Assign pane indices: 'price' → 0, every other pane key in first-seen order.
    const paneIndex = new Map<string, number>([[PRICE_PANE, 0]]);
    for (const o of overlays) {
      if (!paneIndex.has(o.pane)) paneIndex.set(o.pane, paneIndex.size);
    }
    // Ensure enough panes exist.
    while (this.chart.panes().length < paneIndex.size) this.chart.addPane();

    for (const o of overlays) {
      const idx = paneIndex.get(o.pane)!;
      for (const line of o.lines) {
        const s = this.chart.addSeries(LineSeries, {
          color: line.color,
          lineWidth: 1,
          priceLineVisible: false,
          title: line.label,
        }, idx);
        const pts: LineData[] = line.points
          .filter(p => p.v !== null && !Number.isNaN(p.v))
          .map(p => ({ time: Math.floor(p.ts) as Time, value: p.v }));
        s.setData(pts);
        this.overlaySeries.push(s);
      }
    }

    // Give the main price pane more vertical room than oscillator panes.
    const panes = this.chart.panes();
    if (panes.length > 1) {
      panes[0].setStretchFactor(3);
      for (let i = 1; i < panes.length; i++) panes[i].setStretchFactor(1);
    }

    this.chart.timeScale().fitContent();
  }
}
