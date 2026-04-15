import {
  ChangeDetectionStrategy, Component, DestroyRef, computed, effect,
  inject, signal,
} from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { FormsModule } from '@angular/forms';
import {
  Api, Candle, IndicatorSpec, StrategySpec, BacktestResult,
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
        <h1>Finam Trading — OCaml</h1>
        <div class="controls">
          <label>Symbol
            <input [ngModel]="symbol()" (ngModelChange)="symbol.set($event)">
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

  readonly symbol = signal('SBER');
  readonly n = signal(500);
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

    // Reload candles whenever symbol or n change.
    effect(() => {
      const s = this.symbol();
      const count = this.n();
      this.api.candles(s, count)
        .pipe(takeUntilDestroyed(this.destroyRef))
        .subscribe(r => this.candles.set(r.candles));
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

  runBacktest(): void {
    this.api.backtest({
      symbol: this.symbol(),
      strategy: this.strategyName(),
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
