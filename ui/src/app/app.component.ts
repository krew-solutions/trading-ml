import {
  ChangeDetectionStrategy, Component, DestroyRef, computed, effect,
  inject, signal,
} from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { FormsModule } from '@angular/forms';
import {
  Api, Candle, IndicatorSpec, StrategySpec, BacktestResult,
  MICS_FALLBACK, TIMEFRAMES, micLabel,
  type Board, type Mic, type StreamEvent, type Timeframe,
} from './api.service';
import { ChartComponent } from './chart.component';
import { OrdersComponent } from './orders.component';
import {
  emptyOverlay, overlayRegistry, LINE_STYLES,
  type IndicatorOverlay, type LineStyle, type LineWidth, type OverlayStyle,
} from './indicators';

/** A configured indicator instance on the chart. Multiple slots may
 *  reference the same spec (e.g. SMA(20) and SMA(50)). */
interface IndicatorSlot {
  id: number;
  specName: string;
  params: Record<string, number>;
  style: OverlayStyle;
  visible: boolean;
}

const PALETTE = [
  '#f4c430', '#4fc3f7', '#ba68c8', '#ef5350', '#81c784',
  '#ff8a65', '#4db6ac', '#7986cb', '#ffa726', '#26c6da',
];

const LINE_WIDTHS: LineWidth[] = [1, 2, 3, 4];

let nextSlotId = 1;

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [FormsModule, ChartComponent, OrdersComponent],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <div class="layout">
      <header>
        <h1>Stock Trading with OCaml</h1>
        <div class="controls">
          <label>Symbol
            <input [ngModel]="ticker()" (ngModelChange)="ticker.set($event)"
                   style="width: 90px">
          </label>
          <label>Exchange
            <select [ngModel]="mic()" (ngModelChange)="mic.set($event)">
              @for (m of venues(); track m) {
                <option [value]="m">{{m}} — {{label(m)}}</option>
              }
            </select>
          </label>
          <label>Board
            <input [ngModel]="board()" (ngModelChange)="board.set($event)"
                   placeholder="TQBR" style="width: 80px"
                   title="Trading mode within the venue (optional)">
          </label>
          <label>Timeframe
            <select [ngModel]="timeframe()"
                    (ngModelChange)="timeframe.set($event)">
              @for (tf of timeframes; track tf) {
                <option [value]="tf">{{tf}}</option>
              }
            </select>
          </label>
          <label>Bars
            <input type="number" [ngModel]="n()"
                   (ngModelChange)="n.set(+$event)">
          </label>
          <label>Strategy
            <select [ngModel]="strategyName()"
                    (ngModelChange)="strategyName.set($event)">
              @for (s of strategies(); track s.name) {
                <option [value]="s.name">{{s.name}}</option>
              }
            </select>
          </label>
          <label class="live">
            <input type="checkbox" [ngModel]="liveEnabled()"
                   (ngModelChange)="liveEnabled.set($event)">
            Live
          </label>
          <button (click)="runBacktest()">Run backtest</button>
        </div>
      </header>

      @if (currentStrategy(); as spec) {
        @if (spec.params.length) {
          <section class="strategy-params">
            @for (p of spec.params; track p.name) {
              <label class="param" [title]="p.name">
                <span class="param-name">{{p.name}}</span>
                @switch (p.type) {
                  @case ('bool') {
                    <input type="checkbox"
                           [ngModel]="$any(strategyParams()[p.name])"
                           (ngModelChange)="patchStrategyParam(p.name, $event)">
                  }
                  @case ('string') {
                    <input type="text"
                           [ngModel]="$any(strategyParams()[p.name])"
                           (ngModelChange)="patchStrategyParam(p.name, $event)">
                  }
                  @default {
                    <input type="number"
                           [ngModel]="$any(strategyParams()[p.name])"
                           (ngModelChange)="patchStrategyParam(
                             p.name, p.type === 'int' ? +$event : +$event)">
                  }
                }
              </label>
            }
          </section>
        }
      }

      <section class="indicators">
        <div class="ind-header">
          <h3>Indicators</h3>
          <div class="add">
            <select [(ngModel)]="pickedSpecName">
              @for (spec of catalog(); track spec.name) {
                <option [value]="spec.name">{{spec.name}}</option>
              }
            </select>
            <button (click)="addSlot()" [disabled]="!pickedSpecName">
              + Add
            </button>
          </div>
        </div>

        @for (slot of slots(); track slot.id) {
          <div class="slot">
            <label class="visibility">
              <input type="checkbox" [ngModel]="slot.visible"
                     (ngModelChange)="patchSlot(slot.id, { visible: $event })">
              <strong>{{slot.specName}}</strong>
            </label>

            <input class="color" type="color" [ngModel]="slot.style.color"
                   (ngModelChange)="patchStyle(slot.id, { color: $event })"
                   title="line color">

            <select [ngModel]="slot.style.lineStyle ?? 'solid'"
                    (ngModelChange)="patchStyle(slot.id, { lineStyle: $event })"
                    title="line style">
              @for (s of lineStyles; track s) {
                <option [value]="s">{{s}}</option>
              }
            </select>

            <select [ngModel]="slot.style.lineWidth ?? 1"
                    (ngModelChange)="patchStyle(slot.id, {
                      lineWidth: asLineWidth(+$event) })"
                    title="line width">
              @for (w of lineWidths; track w) {
                <option [value]="w">{{w}}px</option>
              }
            </select>

            <label class="opacity" title="opacity">
              <input type="range" min="0.1" max="1" step="0.1"
                     [ngModel]="slot.style.opacity ?? 1"
                     (ngModelChange)="patchStyle(slot.id, { opacity: +$event })">
              <span>{{((slot.style.opacity ?? 1) * 100).toFixed(0)}}%</span>
            </label>

            @for (p of specParams(slot.specName); track p.name) {
              <span class="param" title="{{p.name}}">
                {{p.name}}
                <input type="number" [ngModel]="slot.params[p.name]"
                       (ngModelChange)="patchParam(slot.id, p.name, +$event)">
              </span>
            }

            <button class="remove" (click)="removeSlot(slot.id)"
                    title="remove indicator">×</button>
          </div>
        } @empty {
          <div class="empty">No indicators. Pick one above and click Add.</div>
        }
      </section>

      <app-chart [candles]="candles()" [overlays]="overlays()"
                 [seriesKey]="seriesKey()"></app-chart>

      @if (result(); as r) {
        <section class="result">
          <h3>Backtest — {{strategyName()}}</h3>
          <div class="grid">
            <div><b>Trades:</b> {{r.num_trades}}</div>
            <div><b>Return:</b> {{(r.total_return * 100).toFixed(2)}}%</div>
            <div><b>Max DD:</b> {{(r.max_drawdown * 100).toFixed(2)}}%</div>
            <div><b>Realized PnL:</b> {{r.realized_pnl.toFixed(2)}}</div>
          </div>
        </section>
      }

      <section class="orders-panel">
        <h3>Orders</h3>
        <app-orders></app-orders>
      </section>
    </div>
  `,
  styles: [`
    .layout { max-width: 1400px; margin: 0 auto; padding: 16px; }
    header { display: flex; justify-content: space-between; align-items: center; }
    .controls { display: flex; gap: 12px; align-items: center; }
    .indicators { margin: 16px 0; }
    .ind-header { display: flex; justify-content: space-between; align-items: center; }
    .ind-header .add { display: flex; gap: 6px; }
    .slot {
      display: flex; gap: 10px; align-items: center;
      padding: 6px 0; border-top: 1px solid #1a1d24; flex-wrap: wrap;
    }
    .slot .visibility { min-width: 140px; display: flex; align-items: center; gap: 6px; }
    .slot .color { width: 32px; height: 24px; padding: 0; border: 1px solid #2a2e38; background: none; }
    .slot .opacity { display: flex; align-items: center; gap: 6px; flex: 0 0 auto; }
    .slot .opacity input[type=range] { width: 80px; }
    .slot .opacity span { font-size: 12px; opacity: 0.7; min-width: 36px; text-align: right; }
    .slot .param { display: flex; align-items: center; gap: 4px; opacity: 0.85; flex: 0 0 auto; }
    .slot .param input { width: 60px; }
    .strategy-params {
      display: flex; flex-wrap: wrap; gap: 10px 16px;
      margin: 8px 0 16px; padding: 10px 12px;
      background: #15181f; border: 1px solid #232731; border-radius: 4px;
    }
    .strategy-params .param { display: flex; align-items: center; gap: 6px; font-size: 12px; }
    .strategy-params .param-name { opacity: 0.75; min-width: 88px; }
    .strategy-params input[type=number] { width: 72px; }
    .strategy-params input[type=text] { width: 280px; }
    .slot .remove {
      margin-left: auto; background: none; border: 1px solid #3a2e38;
      color: #ef5350; padding: 2px 8px; cursor: pointer;
    }
    .empty { opacity: 0.5; padding: 8px 0; }
    .result .grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; }
  `],
})
export class AppComponent {
  private readonly api = inject(Api);
  private readonly destroyRef = inject(DestroyRef);

  readonly ticker = signal('SBER');
  readonly mic = signal<Mic>('MISX');
  readonly board = signal<Board>('');
  readonly timeframe = signal<Timeframe>('H1');
  readonly n = signal(500);
  readonly liveEnabled = signal(false);
  readonly timeframes = TIMEFRAMES;
  /** Populated from [/api/exchanges] on startup; falls back to
   *  [MICS_FALLBACK] until the response arrives or if it fails. */
  readonly venues = signal<Mic[]>(MICS_FALLBACK);
  readonly label = micLabel;

  /** Fully-qualified symbol sent to the server: [TICKER@MIC] when no
   *  board is set, [TICKER@MIC/BOARD] otherwise.
   *  Backend parses it via [Instrument.of_qualified]; the symbol must
   *  be qualified (a bare ticker raises). */
  readonly symbol = computed(() => {
    const base = `${this.ticker()}@${this.mic()}`;
    const b = this.board().trim();
    return b ? `${base}/${b}` : base;
  });
  /** Series identity passed to the chart. Changes when the user
   *  switches symbol / timeframe / bar count, which is exactly
   *  when the chart should auto-fit. Live updates never touch it. */
  readonly seriesKey = computed(() =>
    `${this.symbol()}/${this.timeframe()}/${this.n()}`);
  readonly strategyName = signal('');
  readonly strategies = signal<StrategySpec[]>([]);
  /** Current values of the selected strategy's tunable params. Keyed
   *  by param name; shape depends on the spec (number / boolean /
   *  string). Reset from the spec's defaults whenever the user picks
   *  a different strategy — see the [effect] in the constructor. */
  readonly strategyParams = signal<Record<string, unknown>>({});
  readonly currentStrategy = computed(() =>
    this.strategies().find(s => s.name === this.strategyName()));
  readonly catalog = signal<IndicatorSpec[]>([]);
  readonly slots = signal<IndicatorSlot[]>([]);
  readonly candles = signal<Candle[]>([]);
  readonly result = signal<BacktestResult | undefined>(undefined);

  /** Ticked value of the "add" dropdown, kept out of signals because it's
   *  local form state with no derived reactivity. */
  pickedSpecName = '';

  readonly lineStyles = LINE_STYLES;
  readonly lineWidths = LINE_WIDTHS;

  readonly overlays = computed<IndicatorOverlay[]>(() => {
    const cs = this.candles();
    return this.slots()
      .filter(s => s.visible)
      .map(s => {
        const render = overlayRegistry[s.specName];
        return render ? render(cs, s.params, s.style)
                      : emptyOverlay(s.specName);
      });
  });

  constructor() {
    this.api.strategies()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(list => {
        this.strategies.set(list);
        if (!this.strategyName() && list.length) {
          this.strategyName.set(list[0].name);
        }
      });

    /* Reset the param form whenever the picked strategy changes.
       Defaults come straight from the spec — user edits live in
       the signal only until [runBacktest] serialises them. */
    effect(() => {
      const spec = this.currentStrategy();
      if (!spec) return;
      this.strategyParams.set(
        Object.fromEntries(spec.params.map(p => [p.name, p.default])));
    });

    this.api.exchanges()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: r => {
          if (r.exchanges?.length) this.venues.set(r.exchanges);
        },
        error: () => { /* keep the static fallback */ },
      });

    this.api.indicators()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(list => {
        this.catalog.set(list);
        if (!this.pickedSpecName && list.length) {
          this.pickedSpecName = list[0].name;
        }
        // Seed two common indicators so the chart isn't empty on first load.
        if (!this.slots().length) {
          const sma = list.find(s => s.name === 'SMA');
          const ema = list.find(s => s.name === 'EMA');
          const initial: IndicatorSlot[] = [];
          if (sma) initial.push(this.buildSlot(sma, { period: 20 }));
          if (ema) initial.push(this.buildSlot(ema, { period: 50 }));
          this.slots.set(initial);
        }
      });

    // Reload candles whenever symbol, timeframe or n change.
    effect(() => {
      const s = this.symbol();
      const tf = this.timeframe();
      const count = this.n();
      console.warn(`[candles-effect] fetching /api/candles s=${s} tf=${tf} n=${count}`);
      this.api.candles(s, count, tf)
        .pipe(takeUntilDestroyed(this.destroyRef))
        .subscribe(r => {
          console.warn(
            `[candles-effect] candles.set len=${r.candles.length} ` +
            `firstTs=${r.candles[0]?.ts} lastTs=${r.candles[r.candles.length-1]?.ts}`);
          this.candles.set(r.candles);
        });
    });

    // Live stream: one subscription at a time, re-opened when symbol or
    // timeframe changes. [effect] gives us automatic teardown of the
    // previous EventSource on each re-run.
    effect((onCleanup) => {
      if (!this.liveEnabled()) return;
      const s = this.symbol();
      const tf = this.timeframe();
      console.warn(`[stream-effect] opening EventSource s=${s} tf=${tf}`);
      const sub = this.api.stream(s, tf).subscribe({
        next: (ev) => this.applyStreamEvent(ev),
        error: (e) => console.warn('[stream] error', e),
      });
      onCleanup(() => {
        console.warn('[stream-effect] cleanup (closing EventSource)');
        sub.unsubscribe();
      });
    });
  }

  asLineWidth(n: number): LineWidth {
    return (n >= 1 && n <= 4 ? n : 1) as LineWidth;
  }

  specParams(name: string) {
    return this.catalog().find(s => s.name === name)?.params ?? [];
  }

  addSlot(): void {
    const spec = this.catalog().find(s => s.name === this.pickedSpecName);
    if (!spec) return;
    this.slots.update(list => [...list, this.buildSlot(spec)]);
  }

  removeSlot(id: number): void {
    this.slots.update(list => list.filter(s => s.id !== id));
  }

  patchSlot(id: number, patch: Partial<IndicatorSlot>): void {
    this.slots.update(list => list.map(s =>
      s.id === id ? { ...s, ...patch } : s));
  }

  patchStyle(id: number, patch: Partial<OverlayStyle>): void {
    this.slots.update(list => list.map(s =>
      s.id === id ? { ...s, style: { ...s.style, ...patch } } : s));
  }

  patchParam(id: number, key: string, value: number): void {
    this.slots.update(list => list.map(s =>
      s.id === id
        ? { ...s, params: { ...s.params, [key]: value } }
        : s));
  }

  /** Merge an incoming SSE bar event into the candles signal.
   *  - `seed`     — replace the whole array (initial snapshot);
   *  - `updated`  — patch the trailing bar when its ts matches;
   *  - `closed`   — append a new bar (and drop the oldest to keep [n]).
   *
   *  Each event carries [symbol] + [timeframe]; with one feed per
   *  EventSource we trust the server's filter, but a future multi-feed
   *  consumer would dispatch on those fields. */
  applyStreamEvent(ev: StreamEvent): void {
    switch (ev.kind) {
      case 'seed':
        console.warn(
          `[sse] SEED ${ev.symbol}/${ev.timeframe} len=${ev.candles.length} ` +
          `firstTs=${ev.candles[0]?.ts} ` +
          `lastTs=${ev.candles[ev.candles.length-1]?.ts}`);
        if (ev.candles.length) this.candles.set(ev.candles);
        break;
      case 'updated':
        console.debug(`[sse] updated ${ev.symbol}/${ev.timeframe} ` +
          `ts=${ev.candle.ts} close=${ev.candle.close}`);
        this.candles.update(cs => {
          if (!cs.length) return [ev.candle];
          const last = cs[cs.length - 1];
          // Same-ts: replace the trailing bar.
          if (last.ts === ev.candle.ts) return [...cs.slice(0, -1), ev.candle];
          // Strictly older than what we have: stale snapshot, ignore.
          if (ev.candle.ts < last.ts) return cs;
          return [...cs, ev.candle];
        });
        break;
      case 'closed':
        console.debug(`[sse] closed ${ev.symbol}/${ev.timeframe} ` +
          `ts=${ev.candle.ts} close=${ev.candle.close}`);
        this.candles.update(cs => {
          if (!cs.length) return [ev.candle];
          const last = cs[cs.length - 1];
          if (last.ts === ev.candle.ts) {
            return [...cs.slice(0, -1), ev.candle];
          }
          if (ev.candle.ts < last.ts) return cs;
          const appended = [...cs, ev.candle];
          return appended.length > this.n()
            ? appended.slice(appended.length - this.n())
            : appended;
        });
        break;
    }
  }

  patchStrategyParam(name: string, value: unknown): void {
    this.strategyParams.update(p => ({ ...p, [name]: value }));
  }

  runBacktest(): void {
    this.api.backtest({
      symbol: this.symbol(),
      strategy: this.strategyName(),
      timeframe: this.timeframe(),
      params: this.strategyParams() as Record<string, number | boolean | string>,
      n: this.n(),
    })
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe(r => this.result.set(r));
  }

  private buildSlot(
    spec: IndicatorSpec,
    paramOverrides: Record<string, number> = {},
  ): IndicatorSlot {
    const index = this.slots().length;
    return {
      id: nextSlotId++,
      specName: spec.name,
      visible: true,
      params: {
        ...Object.fromEntries(
          spec.params.map(p => [p.name, Number(p.default) || 0])),
        ...paramOverrides,
      },
      style: {
        color: PALETTE[index % PALETTE.length],
        lineWidth: 1,
        lineStyle: 'solid' as LineStyle,
        opacity: 1,
      },
    };
  }
}
