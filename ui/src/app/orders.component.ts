import {
  ChangeDetectionStrategy, Component, inject, signal,
} from '@angular/core';
import { Api, Order, PlaceOrderRequest } from './api.service';

/**
 * Orders panel — lists open/historical orders, places and cancels.
 *
 * Talks to the same `/api/orders` surface as `trading orders` CLI, so
 * paper-mode and live-broker views are identical. Orders are fetched
 * on demand (refresh button) rather than streamed — broker APIs don't
 * reliably push order events, and polling keeps the component simple.
 */
@Component({
  selector: 'app-orders',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [`
    :host { display: block; font: 13px/1.4 monospace; color: #d8dae0; }
    .orders { border-collapse: collapse; width: 100%; margin-top: 8px; }
    .orders th, .orders td { border: 1px solid #2a2e38;
      padding: 4px 8px; text-align: left; }
    .orders th { background: #14171d; }
    .row button { background: #2a2e38; color: #d8dae0;
      border: 1px solid #3a3f4a; padding: 2px 8px; cursor: pointer; }
    .row button:disabled { opacity: 0.4; cursor: default; }
    .empty { color: #6e7687; padding: 12px; }
    form { display: flex; gap: 6px; flex-wrap: wrap;
      margin-bottom: 6px; align-items: center; }
    form input, form select { background: #14171d; color: #d8dae0;
      border: 1px solid #2a2e38; padding: 2px 6px; }
    .err { color: #ef5350; margin-top: 6px; }
  `],
  template: `
    <form (submit)="$event.preventDefault(); onPlace()">
      <input [value]="symbol()"
             (change)="symbol.set(asInput($event).value)"
             placeholder="SBER@MISX" />
      <select [value]="side()"
              (change)="setSide(asInput($event).value)">
        <option>BUY</option>
        <option>SELL</option>
      </select>
      <input type="number" [value]="quantity()"
             (change)="quantity.set(+asInput($event).value)"
             placeholder="qty" style="width: 80px" />
      <select [value]="kind()"
              (change)="setKind(asInput($event).value)">
        <option>MARKET</option>
        <option>LIMIT</option>
        <option>STOP</option>
      </select>
      @if (kind() !== 'MARKET') {
        <input type="number" step="0.01" [value]="price()"
               (change)="price.set(+asInput($event).value)"
               placeholder="price" style="width: 90px" />
      }
      <input [value]="cid()"
             (change)="cid.set(asInput($event).value)"
             placeholder="client_order_id" />
      <button type="submit">Place</button>
      <button type="button" (click)="refresh()">Refresh</button>
    </form>
    @if (error()) { <div class="err">{{ error() }}</div> }
    @if (orders().length === 0) {
      <div class="empty">(no orders)</div>
    } @else {
      <table class="orders">
        <thead><tr>
          <th>cid</th><th>instrument</th><th>side</th>
          <th>qty</th><th>filled</th><th>kind</th><th>status</th><th></th>
        </tr></thead>
        <tbody>
        @for (o of orders(); track o.client_order_id) {
          <tr class="row">
            <td>{{ o.client_order_id }}</td>
            <td>{{ o.instrument }}</td>
            <td>{{ o.side }}</td>
            <td>{{ o.quantity }}</td>
            <td>{{ o.filled }}</td>
            <td>{{ formatKind(o) }}</td>
            <td>{{ o.status }}</td>
            <td><button [disabled]="isDone(o)"
                        (click)="onCancel(o)">Cancel</button></td>
          </tr>
        }
        </tbody>
      </table>
    }
  `,
})
export class OrdersComponent {
  private api = inject(Api);

  readonly orders = signal<Order[]>([]);
  readonly error = signal<string | null>(null);

  readonly symbol = signal<string>('SBER@MISX');
  readonly side = signal<'BUY' | 'SELL'>('BUY');
  readonly quantity = signal<number>(10);
  readonly kind = signal<'MARKET' | 'LIMIT' | 'STOP'>('MARKET');
  readonly price = signal<number>(0);
  readonly cid = signal<string>(this.defaultCid());

  constructor() { this.refresh(); }

  asInput(ev: Event): HTMLInputElement | HTMLSelectElement {
    return ev.target as HTMLInputElement | HTMLSelectElement;
  }

  setSide(v: string): void {
    if (v === 'BUY' || v === 'SELL') this.side.set(v);
  }
  setKind(v: string): void {
    if (v === 'MARKET' || v === 'LIMIT' || v === 'STOP') this.kind.set(v);
  }

  private defaultCid(): string {
    return `ui-${Date.now().toString(36)}`;
  }

  refresh(): void {
    this.api.orders().subscribe({
      next: r => { this.orders.set(r.orders); this.error.set(null); },
      error: e => this.error.set(e.message ?? String(e)),
    });
  }

  onPlace(): void {
    const k = this.kind();
    const kindField = k === 'MARKET'
      ? { type: 'MARKET' as const }
      : { type: k, price: this.price() };
    const req: PlaceOrderRequest = {
      symbol: this.symbol(),
      side: this.side(),
      quantity: this.quantity(),
      client_order_id: this.cid(),
      kind: kindField,
    };
    this.api.placeOrder(req).subscribe({
      next: _ => {
        this.cid.set(this.defaultCid());
        this.refresh();
      },
      error: e => this.error.set(e.error?.error ?? e.message ?? String(e)),
    });
  }

  onCancel(o: Order): void {
    this.api.cancelOrder(o.client_order_id).subscribe({
      next: _ => this.refresh(),
      error: e => this.error.set(e.error?.error ?? e.message ?? String(e)),
    });
  }

  isDone(o: Order): boolean {
    return ['Filled', 'Cancelled', 'Rejected', 'Expired', 'Failed']
      .includes(o.status);
  }

  formatKind(o: Order): string {
    switch (o.kind.type) {
      case 'MARKET': return 'MARKET';
      case 'LIMIT':  return `LIMIT @ ${o.kind.price}`;
      case 'STOP':   return `STOP @ ${o.kind.price}`;
      case 'STOP_LIMIT':
        return `STOP_LIMIT ${o.kind.stop_price}/${o.kind.limit_price}`;
    }
  }
}
