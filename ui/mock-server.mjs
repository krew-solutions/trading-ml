#!/usr/bin/env node
/** Zero-dependency mock backend that mirrors the shape of the OCaml API
 *  so the Angular dev server can run without the OCaml side built.
 *
 *  Endpoints:
 *    GET  /api/indicators
 *    GET  /api/strategies
 *    GET  /api/exchanges
 *    GET  /api/candles?symbol=TICKER@MIC[/BOARD]&n=...&timeframe=...
 *    GET  /api/footprints?symbol=TICKER@MIC[/BOARD]&n=...&timeframe=...
 *    GET  /api/stream?bars=SYM:TF,...&footprints=SYM:TOKEN,...        (SSE)
 *    POST /api/backtest   { symbol: "TICKER@MIC[/BOARD]", ... }
 *
 *  Run:  node mock-server.mjs   (or `npm run mock`)
 *
 *  Keeps the port and response shapes in sync with `lib/server/api.ml` +
 *  `lib/server/http.ml`. If those diverge, update here too. */

import { createServer } from 'node:http';

const PORT = Number(process.env.PORT ?? 8080);

// ─────────────────────────────────────────────────────────────────────────
// Catalogs — mirror lib/indicators/registry.ml and lib/strategies/registry.ml
// ─────────────────────────────────────────────────────────────────────────

const indicatorsCatalog = [
  { name: 'SMA',               params: [{ name: 'period', type: 'int',   default: 20 }] },
  { name: 'EMA',               params: [{ name: 'period', type: 'int',   default: 20 }] },
  { name: 'WMA',               params: [{ name: 'period', type: 'int',   default: 20 }] },
  { name: 'RSI',               params: [{ name: 'period', type: 'int',   default: 14 }] },
  { name: 'MACD',              params: [
      { name: 'fast',   type: 'int', default: 12 },
      { name: 'slow',   type: 'int', default: 26 },
      { name: 'signal', type: 'int', default:  9 },
  ]},
  { name: 'MACD-Weighted',     params: [
      { name: 'fast',   type: 'int', default: 12 },
      { name: 'slow',   type: 'int', default: 26 },
      { name: 'signal', type: 'int', default:  9 },
  ]},
  { name: 'BollingerBands',    params: [
      { name: 'period', type: 'int',   default: 20 },
      { name: 'k',      type: 'float', default:  2 },
  ]},
  { name: 'ATR',               params: [{ name: 'period', type: 'int', default: 14 }] },
  { name: 'OBV',               params: [] },
  { name: 'A/D',               params: [] },
  { name: 'ChaikinOscillator', params: [
      { name: 'fast', type: 'int', default:  3 },
      { name: 'slow', type: 'int', default: 10 },
  ]},
  { name: 'Stochastic',        params: [
      { name: 'k_period', type: 'int', default: 14 },
      { name: 'd_period', type: 'int', default:  3 },
  ]},
  { name: 'MFI', params: [{ name: 'period', type: 'int', default: 14 }] },
  { name: 'CMF', params: [{ name: 'period', type: 'int', default: 20 }] },
  { name: 'CVI', params: [{ name: 'period', type: 'int', default: 10 }] },
  { name: 'CVD', params: [] },
  { name: 'Volume',   params: [] },
  { name: 'VolumeMA', params: [{ name: 'period', type: 'int', default: 20 }] },
];

const strategiesCatalog = [
  { name: 'SMA_Crossover', params: [
      { name: 'fast',        type: 'int',  default: 10 },
      { name: 'slow',        type: 'int',  default: 30 },
      { name: 'allow_short', type: 'bool', default: false },
  ]},
  { name: 'RSI_MeanReversion', params: [
      { name: 'period',      type: 'int',   default: 14 },
      { name: 'lower',       type: 'float', default: 30 },
      { name: 'upper',       type: 'float', default: 70 },
      { name: 'exit_long',   type: 'float', default: 50 },
      { name: 'exit_short',  type: 'float', default: 50 },
      { name: 'allow_short', type: 'bool',  default: false },
  ]},
  { name: 'MACD_Momentum', params: [
      { name: 'fast',        type: 'int',  default: 12 },
      { name: 'slow',        type: 'int',  default: 26 },
      { name: 'signal',      type: 'int',  default:  9 },
      { name: 'allow_short', type: 'bool', default: false },
  ]},
  { name: 'Bollinger_Breakout', params: [
      { name: 'period',      type: 'int',   default: 20 },
      { name: 'k',           type: 'float', default:  2 },
      { name: 'allow_short', type: 'bool',  default: true },
  ]},
  { name: 'MFI_MeanReversion', params: [
      { name: 'period',      type: 'int',   default: 14 },
      { name: 'lower',       type: 'float', default: 20 },
      { name: 'upper',       type: 'float', default: 80 },
      { name: 'exit_long',   type: 'float', default: 50 },
      { name: 'exit_short',  type: 'float', default: 50 },
      { name: 'allow_short', type: 'bool',  default: false },
  ]},
  { name: 'OBV_MA_Crossover', params: [
      { name: 'period',      type: 'int',  default: 20 },
      { name: 'allow_short', type: 'bool', default: false },
  ]},
  { name: 'Chaikin_Momentum', params: [
      { name: 'fast',        type: 'int',  default:  3 },
      { name: 'slow',        type: 'int',  default: 10 },
      { name: 'allow_short', type: 'bool', default: false },
  ]},
  { name: 'AD_MA_Crossover', params: [
      { name: 'period',      type: 'int',  default: 20 },
      { name: 'allow_short', type: 'bool', default: false },
  ]},
];

// ─────────────────────────────────────────────────────────────────────────
// Deterministic synthetic candle stream
// ─────────────────────────────────────────────────────────────────────────

/** Seeded mulberry32 so reloads with the same (symbol, n) return the
 *  same data — feels stable in the UI. */
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hash(str) {
  let h = 2166136261;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/** Seconds-per-bar for each supported timeframe. Mirrors
 *  `Timeframe.to_seconds` in `lib/core/timeframe.ml`. */
const TIMEFRAME_SECONDS = {
  M1: 60, M5: 300, M15: 900, M30: 1800,
  H1: 3600, H4: 14400,
  D1: 86400, W1: 604800, MN1: 2592000,
};

function generateCandles({
  symbol = 'SBER@MISX', n = 500, timeframe = 'H1',
} = {}) {
  const tfSeconds = TIMEFRAME_SECONDS[timeframe] ?? 3600;
  const rng = mulberry32(hash(`${symbol}:${timeframe}:${n}`));
  const startTs = 1_704_067_200;   // 2024-01-01 UTC
  let price = 100 + rng() * 50;
  const out = [];
  for (let i = 0; i < n; i++) {
    const drift = (rng() * 2 - 1) * 0.6;
    const close = Math.max(1, price + drift);
    const high  = Math.max(price, close) + rng() * 0.7;
    const low   = Math.max(0.5, Math.min(price, close) - rng() * 0.7);
    const volume = 500 + Math.floor(rng() * 5000);
    out.push({
      ts: startTs + i * tfSeconds,
      open:   moneyStr(price),
      high:   moneyStr(high),
      low:    moneyStr(low),
      close:  moneyStr(close),
      volume: intStr(volume),
    });
    price = close;
  }
  return out;
}

/** Split a qualified symbol TICKER@MIC[/BOARD] into the instrument view
 *  model the footprint DTO nests. */
function parseInstrument(symbol) {
  const [base, board] = symbol.split('/');
  const [ticker, venue] = base.split('@');
  const inst = { ticker: ticker || 'SBER', venue: venue || 'MISX' };
  if (board) inst.board = board;
  return inst;
}

/** One synthetic footprint bar from a generated candle: spread the bar's
 *  volume across a few price levels between low and high, split by
 *  aggressor with a seeded bias, so the UI's cluster grid and true-CVD
 *  line have plausible (deterministic) data without the OCaml backend.
 *  Shape mirrors `footprint_completed_integration_event` exactly — the
 *  UI validates it through the atdts-generated reader. */
function footprintOfCandle(candle, instrument, timeframe, rng) {
  const low = Number(candle.low);
  const high = Number(candle.high);
  const vol = Number(candle.volume);
  const levels = 5 + Math.floor(rng() * 5);   // 5..9 price levels
  const step = (high - low) / Math.max(1, levels - 1);
  const clusters = [];
  let buyTotal = 0, sellTotal = 0;
  let poc = { price: low, total: -1 };
  for (let i = 0; i < levels; i++) {
    const price = round(low + i * step);
    const levelVol = (vol / levels) * (0.5 + rng());
    const buyFrac = 0.3 + rng() * 0.4;          // 0.3..0.7 to buyers
    const buy = round(levelVol * buyFrac);
    const sell = round(levelVol * (1 - buyFrac));
    const indet = i === 0 ? round(levelVol * 0.1 * rng()) : 0; // a little auction at the low
    buyTotal += buy; sellTotal += sell;
    const total = buy + sell + indet;
    if (total > poc.total) poc = { price, total };
    clusters.push({
      price: moneyStr(price),
      buy_volume: moneyStr(buy),
      sell_volume: moneyStr(sell),
      indeterminate_volume: moneyStr(indet),
    });
  }
  return {
    instrument,
    timeframe,
    open_ts: new Date(candle.ts * 1000).toISOString(),
    open_price: candle.open,
    high: candle.high,
    low: candle.low,
    close: candle.close,
    volume: candle.volume,
    delta: moneyStr(buyTotal - sellTotal),
    poc_price: moneyStr(poc.price),
    clusters,
  };
}

/** Deterministic footprint history for a feed, oldest-first — the shape
 *  GET /api/footprints returns and the SSE footprint channel streams. */
function generateFootprints({ symbol = 'SBER@MISX', n = 200, timeframe = 'M5' } = {}) {
  const candles = generateCandles({ symbol, n, timeframe });
  const instrument = parseInstrument(symbol);
  const rng = mulberry32(hash(`fp:${symbol}:${timeframe}:${n}`));
  return candles.map(c => footprintOfCandle(c, instrument, timeframe, rng));
}

const round = (x) => Math.round(x * 100) / 100;

/** Canonical decimal string matching the OCaml `Core.Decimal.to_string`
 *  output: trailing zeros trimmed, integer values printed without `.`.
 *  Two-decimal precision is enough for the synthetic prices generated
 *  here — kopeck level on equities. */
const moneyStr = (x) => {
  const n = round(x);
  return Number.isInteger(n) ? String(n) : n.toFixed(2).replace(/0+$/, '').replace(/\.$/, '');
};
const intStr = (n) => String(n);

// ─────────────────────────────────────────────────────────────────────────
// Plausible backtest result — just enough for the UI to render the panel
// ─────────────────────────────────────────────────────────────────────────

function runBacktest({ symbol, strategy, n = 500, timeframe = 'H1' }) {
  const candles = generateCandles({ symbol, n, timeframe });
  const rng = mulberry32(hash(`bt:${symbol}:${strategy}:${timeframe}:${n}`));
  const numTrades = 3 + Math.floor(rng() * 15);
  const totalReturn = (rng() * 0.3) - 0.05;   // -5% … +25%
  const maxDrawdown = rng() * 0.2;            //  0% … 20%
  const initialCash = 1_000_000;
  const finalCash = initialCash * (1 + totalReturn);
  const realizedPnl = finalCash - initialCash;

  // Fake equity curve: random walk anchored at initialCash ending near finalCash.
  const equityCurve = [];
  for (let i = 0; i < candles.length; i++) {
    const progress = i / (candles.length - 1);
    const noise = (rng() - 0.5) * initialCash * 0.03;
    equityCurve.push({
      ts: candles[i].ts,
      equity: moneyStr(initialCash + (finalCash - initialCash) * progress + noise),
    });
  }

  // Scatter a few synthetic fills.
  const fills = [];
  for (let i = 0; i < numTrades; i++) {
    const idx = Math.floor(rng() * candles.length);
    const c = candles[idx];
    /* c.close is already a moneyStr; convert back for the fee math
       and re-emit as a money string. */
    const closeNum = Number(c.close);
    fills.push({
      ts: c.ts,
      side: rng() > 0.5 ? 'BUY' : 'SELL',
      quantity: intStr(100),
      price: c.close,
      fee: moneyStr(closeNum * 100 * 0.0005),
      reason: `mock ${strategy} signal`,
    });
  }

  return {
    num_trades: numTrades,
    total_return: totalReturn,    // domain ratio, stays float on wire
    max_drawdown: maxDrawdown,    // domain ratio, stays float on wire
    final_cash: moneyStr(finalCash),
    realized_pnl: moneyStr(realizedPnl),
    equity_curve: equityCurve,
    fills,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// HTTP wiring
// ─────────────────────────────────────────────────────────────────────────

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function json(res, body, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...CORS });
  res.end(JSON.stringify(body));
}

/** Parse a `SYM@MIC[/BOARD]:TOKEN` feed spec. The token (timeframe, or a
 *  "VOL:1000" volume cap) may itself contain a colon, so split on the
 *  FIRST one — matching the backend's bars / footprints param parsing. */
function parseFeed(spec) {
  const i = spec.indexOf(':');
  if (i < 0) return null;
  const symbol = spec.slice(0, i);
  const token = spec.slice(i + 1);
  return symbol && token ? { symbol, token } : null;
}

/** SSE stream mirroring the OCaml server's named channels. Subscriptions
 *  come as `?bars=SYM:TF,...` (event: bar) and `?footprints=SYM:TOKEN,...`
 *  (event: footprint), each framed with an explicit `event:` line so the
 *  browser's addEventListener('bar' | 'footprint') fires — a bare `data:`
 *  would only trigger the default message handler. Bars seed + live-mutate
 *  the trailing candle; footprints emit one new sealed bar per tick. */
function serveSse(req, res, url) {
  const barFeeds = (url.searchParams.get('bars') || '')
    .split(',').map(s => s.trim()).filter(Boolean).map(parseFeed).filter(Boolean);
  const fpFeeds = (url.searchParams.get('footprints') || '')
    .split(',').map(s => s.trim()).filter(Boolean).map(parseFeed).filter(Boolean);

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
    ...CORS,
  });

  /** Named-channel SSE frame: `event: <ch>\ndata: <json>\n\n`. */
  const send = (channel, data) => {
    res.write(`event: ${channel}\ndata: ${JSON.stringify(data)}\n\n`);
  };

  const timers = [];

  // ── bar feeds ──────────────────────────────────────────────────────
  for (const { symbol, token: timeframe } of barFeeds) {
    const tfSeconds = TIMEFRAME_SECONDS[timeframe] ?? 3600;
    const interval = Math.min(30_000, Math.max(2_000, tfSeconds * 1000 / 12));
    let candles = generateCandles({ symbol, n: 500, timeframe });
    send('bar', { kind: 'seed', symbol, timeframe, candles });
    const rng = mulberry32(hash(`sse:${symbol}:${timeframe}`));
    timers.push(setInterval(() => {
      const last = candles[candles.length - 1];
      const close = Math.max(1, round(Number(last.close) + (rng() - 0.5) * 0.6));
      const candle = {
        ...last,
        high: moneyStr(Math.max(Number(last.high), close)),
        low: moneyStr(Math.min(Number(last.low), close)),
        close: moneyStr(close),
        volume: intStr(Number(last.volume) + Math.floor(rng() * 200)),
      };
      candles = [...candles.slice(0, -1), candle];
      send('bar', { kind: 'updated', symbol, timeframe, candle });
    }, interval));
  }

  // ── footprint feeds ────────────────────────────────────────────────
  for (const { symbol, token } of fpFeeds) {
    const tfSeconds = TIMEFRAME_SECONDS[token] ?? 300;
    const interval = Math.min(30_000, Math.max(2_000, tfSeconds * 1000 / 12));
    const instrument = parseInstrument(symbol);
    const rng = mulberry32(hash(`sse-fp:${symbol}:${token}`));
    // Continue the series after the seeded history so live seals don't
    // collide with what /api/footprints already returned.
    let ts = 1_704_067_200 + 200 * tfSeconds;
    timers.push(setInterval(() => {
      const candles = generateCandles({ symbol, n: 1, timeframe: token });
      const candle = { ...candles[0], ts };
      const payload = footprintOfCandle(candle, instrument, token, rng);
      send('footprint', { kind: 'footprint', payload });
      ts += tfSeconds;
    }, interval));
  }

  req.on('close', () => timers.forEach(clearInterval));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      try {
        const raw = Buffer.concat(chunks).toString('utf8');
        resolve(raw ? JSON.parse(raw) : {});
      } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

// ─────────────────────────────────────────────────────────────────────────
// Orders — in-memory book, mirrors Paper.Paper_broker semantics. Orders
// go straight to Filled so the UI can exercise the lifecycle; refresh
// the page to reset.
// ─────────────────────────────────────────────────────────────────────────

const ordersBook = new Map();

function ordersList() { return [...ordersBook.values()]; }

/** All kind-specific price slots are present on the wire as either a
 *  decimal string or explicit JSON `null`, mirroring how OCaml's
 *  `ppx_yojson_conv` serialises `string option`. The mock fills in
 *  the missing slots so downstream type-checks line up. */
function normaliseKind(k) {
  const base = { type: 'MARKET', price: null, stop_price: null, limit_price: null };
  if (!k) return base;
  return { ...base, ...k };
}

function placeOrderMock(body) {
  const cid = body?.client_order_id ?? `mock-${Date.now()}`;
  /* Wire-shape body: quantity is a decimal string. We keep it as-is
     in the response and echo it as `filled` (paper fills instantly).
     Default to `"0"` if absent — strings everywhere on the wire. */
  const qty = String(body?.quantity ?? '0');
  const order = {
    client_order_id: cid,
    id: cid,
    instrument: body?.symbol ?? 'SBER@MISX',
    side: body?.side ?? 'BUY',
    quantity:  qty,
    filled:    qty,
    remaining: '0',
    status: 'Filled',
    tif: body?.tif ?? 'DAY',
    kind: normaliseKind(body?.kind),
    ts: Math.floor(Date.now() / 1000),
  };
  ordersBook.set(cid, order);
  return order;
}

function getOrderMock(cid) {
  const o = ordersBook.get(cid);
  if (!o) throw new Error(`no order ${cid}`);
  return o;
}

function cancelOrderMock(cid) {
  const o = ordersBook.get(cid);
  if (!o) throw new Error(`no order ${cid}`);
  const cancelled = { ...o, status: 'Cancelled', filled: '0', remaining: o.quantity };
  ordersBook.set(cid, cancelled);
  return cancelled;
}

const server = createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS);
    res.end();
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;

  try {
    if (req.method === 'GET' && path === '/api/indicators') {
      return json(res, indicatorsCatalog);
    }
    if (req.method === 'GET' && path === '/api/strategies') {
      return json(res, strategiesCatalog);
    }
    if (req.method === 'GET' && path === '/api/exchanges') {
      return json(res, { exchanges: ['MISX', 'IEXG'] });
    }
    if (req.method === 'GET' && path === '/api/candles') {
      const symbol = url.searchParams.get('symbol') || 'SBER@MISX';
      const n = Number(url.searchParams.get('n') ?? 500);
      const timeframe = url.searchParams.get('timeframe') || 'H1';
      return json(res, { candles:
        generateCandles({ symbol, n, timeframe }) });
    }
    if (req.method === 'GET' && path === '/api/footprints') {
      const symbol = url.searchParams.get('symbol') || 'SBER@MISX';
      const n = Number(url.searchParams.get('n') ?? 200);
      const timeframe = url.searchParams.get('timeframe') || 'M5';
      return json(res, { footprints:
        generateFootprints({ symbol, n, timeframe }) });
    }
    if (req.method === 'POST' && path === '/api/backtest') {
      const body = await readBody(req);
      return json(res, runBacktest(body));
    }
    if (req.method === 'GET' && path === '/api/stream') {
      return serveSse(req, res, url);
    }
    if (req.method === 'GET' && path === '/api/orders') {
      return json(res, { orders: ordersList() });
    }
    if (req.method === 'POST' && path === '/api/orders') {
      const body = await readBody(req);
      return json(res, placeOrderMock(body));
    }
    if (path.startsWith('/api/orders/')) {
      const cid = decodeURIComponent(path.slice('/api/orders/'.length));
      if (req.method === 'GET')    return json(res, getOrderMock(cid));
      if (req.method === 'DELETE') return json(res, cancelOrderMock(cid));
    }
    if (req.method === 'GET' && (path === '/' || path === '/health')) {
      res.writeHead(200, { 'Content-Type': 'text/plain', ...CORS });
      res.end('mock ok');
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain', ...CORS });
    res.end('not found');
  } catch (e) {
    json(res, { error: String(e) }, 500);
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`mock-server: listening on http://127.0.0.1:${PORT}`);
  console.log('  GET  /api/indicators');
  console.log('  GET  /api/strategies');
  console.log('  GET  /api/candles?symbol=SBER@MISX&n=500&timeframe=H1');
  console.log('  GET  /api/footprints?symbol=SBER@MISX&n=200&timeframe=M5');
  console.log('  GET  /api/stream?bars=SBER@MISX:H1&footprints=SBER@MISX:M5   (SSE)');
  console.log('  POST /api/backtest   { symbol: "SBER@MISX[/BOARD]", strategy, params, n }');
});
