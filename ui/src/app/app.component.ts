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
  imports: [FormsModule, ChartComponent],
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

      <app-chart [candles]="candles()" [overlays]="overlays()"></app-chart>

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
  readonly strategyName = signal('');
  readonly strategies = signal<StrategySpec[]>([]);
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
      this.api.candles(s, count, tf)
        .pipe(takeUntilDestroyed(this.destroyRef))
        .subscribe(r => this.candles.set(r.candles));
    });

    // Live stream: one subscription at a time, re-opened when symbol or
    // timeframe changes. [effect] gives us automatic teardown of the
    // previous EventSource on each re-run.
    effect((onCleanup) => {
      if (!this.liveEnabled()) return;
      const s = this.symbol();
      const tf = this.timeframe();
      const sub = this.api.stream(s, tf).subscribe({
        next: (ev) => this.applyStreamEvent(ev),
        error: (e) => console.warn('[stream]', e),
      });
      onCleanup(() => sub.unsubscribe());
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

  /** Merge an incoming SSE event into the candles signal.
   *  - `seed`       — replace the whole array (initial snapshot);
   *  - `bar_update` — patch the trailing bar when its ts matches;
   *  - `bar_closed` — append a new bar (and drop the oldest to keep [n]). */
  applyStreamEvent(ev: StreamEvent): void {
    switch (ev.kind) {
      case 'seed':
        if (ev.candles.length) this.candles.set(ev.candles);
        break;
      case 'bar_update':
        this.candles.update(cs => {
          if (!cs.length) return [ev.candle];
          const last = cs[cs.length - 1];
          // Same-ts: replace the trailing bar.
          if (last.ts === ev.candle.ts) return [...cs.slice(0, -1), ev.candle];
          // Strictly older than what we have: stale snapshot, ignore.
          // (lightweight-charts asserts ascending order, so appending
          //  backwards breaks the chart.)
          if (ev.candle.ts < last.ts) return cs;
          return [...cs, ev.candle];
        });
        break;
      case 'bar_closed':
        this.candles.update(cs => {
          if (!cs.length) return [ev.candle];
          const last = cs[cs.length - 1];
          if (last.ts === ev.candle.ts) {
            return [...cs.slice(0, -1), ev.candle];
          }
          // Out-of-order defence — see bar_update above.
          if (ev.candle.ts < last.ts) return cs;
          const appended = [...cs, ev.candle];
          return appended.length > this.n()
            ? appended.slice(appended.length - this.n())
            : appended;
        });
        break;
    }
  }

  runBacktest(): void {
    this.api.backtest({
      symbol: this.symbol(),
      strategy: this.strategyName(),
      timeframe: this.timeframe(),
      params: {},
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
